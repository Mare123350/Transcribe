@preconcurrency import AVFoundation
import AudioCapture
import Foundation
import Observation
import SwiftData
import Transcriber

/// Runs a recording: microphone → transcriber → transcript items, with autosave every 30 seconds.
@MainActor
@Observable
final class RecordingController {
    enum State: Equatable {
        case idle, starting, recording, paused, stopping
    }

    private(set) var state: State = .idle
    private(set) var session: Session?
    /// In-progress words that may still change; shown in grey after the transcript.
    private(set) var volatileText = ""
    private(set) var level: Float = 0
    private(set) var statusMessage = ""
    private(set) var engine: TranscriberEngine?
    private(set) var lastAutosave: Date?
    /// How long the last start took, from pressing Record to listening.
    private(set) var lastStartDuration: Duration?
    /// Where the start time went, for diagnosing slow starts.
    private(set) var lastStartPhases: [(String, Duration)] = []
    var problem: PermissionProblem?
    var errorMessage: String?

    /// Called for each finalized segment, after it has been added to the session.
    var onSegment: ((TranscriptItem, Session) -> Void)?
    /// Called with the in-progress text as it changes, for detection before the phrase ends.
    var onVolatile: ((String, Session) -> Void)?
    /// Called about once a second while recording, with the current recording time.
    var onTick: ((TimeInterval, Session) -> Void)?

    private let context: ModelContext
    private let capture = AudioCaptureEngine()
    private var transcriber: (any LiveTranscriber)?
    private var eventsTask: Task<Void, Never>?
    private var forwardTask: Task<Void, Never>?
    private var autosaveTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    /// Keeps macOS from napping the app or sleeping while a service is recorded, even when the
    /// operator has another app in front.
    private var activity: NSObjectProtocol?
    /// Recording time already in the session before this run started, so timestamps keep counting.
    private var timeOffset: TimeInterval = 0
    private var latestAudioTime: TimeInterval = 0
    /// Audio already given to earlier transcribers in this run (after a restart), so timestamps
    /// from a fresh transcriber continue where the last one stopped.
    private var transcriberOffset: TimeInterval = 0
    private var sink: AudioSink?
    private var restarts: [Date] = []
    private var generation = 0
    private var localeID = ""
    /// For the elapsed-time display: when the current run (since start or resume) began.
    private var runStartedAt: Date?
    private var runAccumulated: TimeInterval = 0

    static let autosaveInterval: Duration = .seconds(30)

    init(context: ModelContext) {
        self.context = context
        Task { await capture.prepare() }
    }

    var isActive: Bool { state == .recording || state == .paused || state == .starting }

    /// Current position in the recording, for timestamping things inserted by hand.
    var currentTime: TimeInterval { timeOffset + latestAudioTime }

    /// Recording time shown while recording, counting live (not just when text arrives).
    func elapsed(at date: Date) -> TimeInterval {
        timeOffset + runAccumulated + (runStartedAt.map { date.timeIntervalSince($0) } ?? 0)
    }

    // MARK: - Controls

    func toggleRecordPause(into session: Session) async {
        switch state {
        case .idle: await start(into: session)
        case .recording: await pause()
        case .paused: await resume()
        case .starting, .stopping: break
        }
    }

    func start(into session: Session) async {
        guard state == .idle else { return }
        let startedAt = ContinuousClock.now
        var phaseStart = startedAt
        var phases: [(String, Duration)] = []
        func mark(_ name: String) {
            let now = ContinuousClock.now
            phases.append((name, now - phaseStart))
            phaseStart = now
        }
        state = .starting
        errorMessage = nil
        problem = nil

        guard await AudioCaptureEngine.requestMicrophoneAccess() else {
            problem = .microphone
            state = .idle
            return
        }
        mark("microphone permission")

        let defaults = UserDefaults.standard
        let localeID = defaults.string(forKey: SettingsKey.locale) ?? Locale.current.identifier
        let deviceUID = defaults.string(forKey: SettingsKey.inputDeviceUID) ?? ""
        let deviceID = deviceUID.isEmpty ? nil : AudioDeviceCatalog.device(withUID: deviceUID)?.id

        do {
            // Open the input and prepare the speech model at the same time.
            async let made = TranscriberFactory.make(locale: Locale(identifier: localeID))
            #if DEBUG
            let fileAudio = try Self.debugFileAudio()
            let captured: AsyncStream<AudioChunk>
            if let fileAudio { captured = fileAudio } else { captured = try await capture.start(deviceID: deviceID) }
            #else
            let captured = try await capture.start(deviceID: deviceID)
            #endif
            mark("audio input")
            let transcriber = try await made
            mark("speech model lookup")
            let (audio, audioOutput) = AsyncStream.makeStream(of: AudioChunk.self, bufferingPolicy: .bufferingNewest(256))
            let sink = AudioSink(audioOutput)
            self.sink = sink
            forwardTask = Task.detached { [weak self] in
                var lastLevel = ContinuousClock.now
                for await chunk in captured {
                    sink.yield(chunk)
                    let now = ContinuousClock.now
                    if now - lastLevel > .milliseconds(80) {
                        lastLevel = now
                        let level = chunk.level
                        await MainActor.run { self?.level = level }
                    }
                }
                sink.finish()
            }

            let events = try await transcriber.start(audio: audio)
            mark("speech analyzer start")
            self.transcriber = transcriber
            self.engine = transcriber.engine
            self.session = session
            timeOffset = session.duration
            latestAudioTime = 0
            transcriberOffset = 0
            restarts = []
            self.localeID = localeID
            runAccumulated = 0
            runStartedAt = .now
            session.isRecording = true
            session.localeIdentifier = localeID
            session.engineName = transcriber.engine.rawValue
            save()

            listen(to: events)
            startAutosave()
            startTicks()
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled, .latencyCritical],
                reason: "Recording and transcribing a service"
            )
            state = .recording
            lastStartDuration = ContinuousClock.now - startedAt
            lastStartPhases = phases
        } catch let error as TranscriberError where error == .speechPermissionDenied {
            await capture.stop()
            problem = .speechRecognition
            state = .idle
        } catch let error as AudioCaptureError {
            await capture.stop()
            if case .microphoneDenied = error { problem = .microphone } else { errorMessage = error.localizedDescription }
            state = .idle
        } catch {
            await capture.stop()
            errorMessage = Self.describe(error)
            state = .idle
        }
    }

    func pause() async {
        guard state == .recording else { return }
        await capture.pause()
        level = 0
        if let runStartedAt { runAccumulated += Date.now.timeIntervalSince(runStartedAt) }
        runStartedAt = nil
        state = .paused
        save()
    }

    func resume() async {
        guard state == .paused else { return }
        do {
            try await capture.resume()
            runStartedAt = .now
            state = .recording
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    func stop() async {
        guard state == .recording || state == .paused else { return }
        state = .stopping
        await capture.stop()
        #if DEBUG
        Self.debugFileTask?.cancel()
        #endif
        await forwardTask?.value
        await transcriber?.finish()
        await eventsTask?.value
        finishSession()
    }

    #if DEBUG
    func debugSetVolatile(_ text: String) { volatileText = text }

    /// Shows the recording state without a microphone, for screenshots.
    func debugSimulateRecording(in session: Session) {
        self.session = session
        timeOffset = 0
        runAccumulated = 754
        runStartedAt = .now
        level = 0.62
        volatileText = "But waiting on God means letting him be God, and trusting his timing"
        state = .recording
    }
    #endif

    // MARK: - Events

    private func listen(to events: AsyncThrowingStream<TranscriptionEvent, Error>) {
        generation += 1
        let current = generation
        let offset = transcriberOffset
        eventsTask = Task { [weak self] in
            var failure: Error?
            do {
                // A replaced recognizer still delivers its last words; only the current one
                // decides what happens when its stream ends.
                for try await event in events {
                    guard let self else { return }
                    if self.generation != current, case .volatile = event { continue }
                    self.handle(event, offset: offset)
                }
            } catch {
                failure = error
            }
            guard let self, self.generation == current else { return }
            await self.transcriberEnded(failure)
        }
    }

    /// The speech recognizer stopped while still recording (an error, or a system limit). Start
    /// a fresh one on the same audio, so the recording carries on without losing words.
    private func transcriberEnded(_ failure: Error?) async {
        guard state == .recording || state == .paused, let sink else {
            if let failure, state != .stopping { errorMessage = Self.describe(failure) }
            didFinishEvents()
            return
        }
        restarts = restarts.filter { Date.now.timeIntervalSince($0) < 60 } + [.now]
        guard restarts.count <= 5 else {
            errorMessage = failure.map(Self.describe) ?? "Speech recognition kept stopping."
            didFinishEvents()
            return
        }
        do {
            let fresh = try await TranscriberFactory.make(locale: Locale(identifier: localeID))
            let (audio, output) = AsyncStream.makeStream(of: AudioChunk.self, bufferingPolicy: .bufferingNewest(256))
            // Audio arriving from now on goes to the new recognizer; nothing is dropped.
            let previous = transcriber
            // New audio waits in the new stream's buffer (about 20 seconds) while the old
            // recognizer finishes the words it already heard; the two never run at once.
            transcriberOffset = sink.replace(with: output)
            if let previous { await Self.finish(previous, within: .seconds(5)) }
            let events = try await fresh.start(audio: audio)
            transcriber = fresh
            listen(to: events)
            statusMessage = "Speech recognition restarted"
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                if self?.statusMessage == "Speech recognition restarted" { self?.statusMessage = "" }
            }
        } catch {
            errorMessage = Self.describe(error)
            didFinishEvents()
        }
    }

    #if DEBUG
    /// `-AudioFile <name>`: plays a file from the app's temporary folder through the pipeline at
    /// real-time speed instead of the microphone, for repeatable tests that hear nothing else.
    private static func debugFileAudio() throws -> AsyncStream<AudioChunk>? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "-AudioFile"), index + 1 < arguments.count else { return nil }
        let file = try AVAudioFile(forReading: URL.temporaryDirectory.appending(path: arguments[index + 1]))
        let (stream, output) = AsyncStream.makeStream(of: AudioChunk.self)
        let box = UncheckedFile(file: file)
        debugFileTask = Task.detached {
            let file = box.file
            while file.framePosition < file.length {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else { break }
                try? file.read(into: buffer, frameCount: 4096)
                output.yield(AudioChunk(buffer: buffer, level: 0.5))
                try? await Task.sleep(for: .seconds(Double(buffer.frameLength) / buffer.format.sampleRate))
            }
            // Silence afterwards, like a quiet room, until recording stops.
            let format = file.processingFormat
            while !Task.isCancelled {
                guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else { break }
                silence.frameLength = 4096
                output.yield(AudioChunk(buffer: silence, level: 0))
                try? await Task.sleep(for: .seconds(4096 / format.sampleRate))
            }
            output.finish()
        }
        return stream
    }

    private struct UncheckedFile: @unchecked Sendable { let file: AVAudioFile }
    private static var debugFileTask: Task<Void, Never>?
    #endif

    private static func finish(_ transcriber: any LiveTranscriber, within limit: Duration) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await transcriber.finish() }
            group.addTask { try? await Task.sleep(for: limit) }
            await group.next()
            group.cancelAll()
        }
    }

    #if DEBUG
    /// Simulates the recognizer failing mid-service, to check the restart.
    func debugInterruptTranscriber() async {
        generation += 1
        await transcriberEnded(TranscriberError.noAudioFormat)
    }
    #endif

    private func handle(_ event: TranscriptionEvent, offset: TimeInterval) {
        switch event {
        case .volatile(let text):
            volatileText = text
            if let session { onVolatile?(text, session) }
        case .status(let message):
            statusMessage = message
        case .finalized(let segment, let pending):
            append(segment, offset: offset)
            // The finished line and what's being said next appear together: no flicker, no repeat.
            volatileText = pending
            if let session, !pending.isEmpty { onVolatile?(pending, session) }
        }
    }

    private func append(_ segment: TranscribedSegment, offset: TimeInterval) {
        guard let session else { return }
        let start = offset + segment.start
        let item = TranscriptItem(kind: .segment, sortIndex: session.nextSortIndex, timestamp: timeOffset + start)
        item.text = segment.text
        item.endTimestamp = timeOffset + offset + max(segment.end, segment.start)
        context.insert(item)
        item.session = session
        latestAudioTime = max(latestAudioTime, offset + segment.end)
        session.duration = max(session.duration, item.endTimestamp)
        session.updatedAt = .now
        onSegment?(item, session)
    }

    private func didFinishEvents() {
        // The transcriber stopped on its own (e.g. an error). Tidy up as if Stop was pressed.
        if state == .recording || state == .paused {
            Task { await self.stop() }
        }
    }

    private func finishSession() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        Task { await capture.prepare() }
        autosaveTask?.cancel()
        tickTask?.cancel()
        session?.isRecording = false
        save()
        transcriber = nil
        sink = nil
        runStartedAt = nil
        eventsTask = nil
        forwardTask = nil
        volatileText = ""
        statusMessage = ""
        level = 0
        state = .idle
    }

    // MARK: - Persistence

    func save() {
        do {
            if context.hasChanges { try context.save() }
            lastAutosave = .now
        } catch {
            errorMessage = "Couldn't save: \(error.localizedDescription)"
        }
    }

    private func startAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.autosaveInterval)
                guard !Task.isCancelled else { return }
                self?.save()
            }
        }
    }

    private func startTicks() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let session = self.session, self.state == .recording else { continue }
                self.onTick?(self.currentTime, session)
            }
        }
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

/// Where captured audio goes. Swapped to a new stream when the recognizer is restarted, and
/// counts the audio sent so far so the new recognizer's timestamps can be offset.
final class AudioSink: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<AudioChunk>.Continuation
    private var seconds: TimeInterval = 0

    init(_ continuation: AsyncStream<AudioChunk>.Continuation) {
        self.continuation = continuation
    }

    func yield(_ chunk: AudioChunk) {
        lock.withLock {
            continuation.yield(chunk)
            seconds += Double(chunk.buffer.frameLength) / chunk.buffer.format.sampleRate
        }
    }

    /// Ends the current stream and sends future audio to `next`. Returns the seconds sent so far.
    func replace(with next: AsyncStream<AudioChunk>.Continuation) -> TimeInterval {
        lock.withLock {
            continuation.finish()
            continuation = next
            return seconds
        }
    }

    func finish() {
        lock.withLock { continuation.finish() }
    }
}
