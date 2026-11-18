@preconcurrency import AVFoundation
import AudioCapture
import Foundation
import Observation
import SwiftData
import Transcriber

/// Runs a recording: microphone → transcriber → transcript items, with a save every 30 seconds.
///
/// The audio is always saved (see `ServiceAudio`). What happens to the words depends on
/// `TranscriptMode`: in "Scripture and songs only" they go to detection and a 30-second rolling
/// buffer, and are never added to the service; in "Full transcript" each finished phrase is saved.
/// Live text reaches the views at most four times a second.
@MainActor
@Observable
final class RecordingController {
    enum State: Equatable {
        case idle, starting, recording, paused, stopping
    }

    private(set) var state: State = .idle
    private(set) var session: Session?
    /// In-progress words that may still change; shown in grey after the transcript. Updated at
    /// most four times a second.
    private(set) var volatileText = ""
    /// The last few words heard (finished and in progress), for the one-line "Listening…" row.
    private(set) var heardLine = ""
    /// Read by the level meter's own timer; not observed, so it never redraws SwiftUI views.
    @ObservationIgnored private(set) var level: Float = 0
    /// What this recording keeps of the words (fixed when recording starts).
    private(set) var mode: TranscriptMode = .detections
    /// The last 30 seconds of finished speech.
    @ObservationIgnored private(set) var recentSpeech = RollingTranscript()
    /// Set when the audio couldn't be saved (shown in the toolbar until recording stops).
    private(set) var audioProblem: String?
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
    private var audioWriter: AudioFileWriter?
    /// Live text waiting to be shown, and the task that shows it.
    @ObservationIgnored private var pendingVolatile: String?
    @ObservationIgnored private var publishTask: Task<Void, Never>?
    /// The service's length is written every few seconds, not per phrase: views showing the
    /// service would otherwise redraw for every phrase.
    @ObservationIgnored private var pendingDuration: TimeInterval = 0
    @ObservationIgnored private var lastDurationWrite = Date.distantPast

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
            // Each run (start or continue) is its own file, named by where it starts in the service.
            let writer = AudioFileWriter(url: ServiceAudio.newPart(for: session.id, startingAt: session.duration))
            writer.onFailure = { [weak self] message in
                Task { @MainActor in self?.audioProblem = "Audio isn't being saved: \(message)" }
            }
            audioWriter = writer
            forwardTask = Task.detached { [weak self] in
                var lastLevel = ContinuousClock.now
                for await chunk in captured {
                    sink.yield(chunk)
                    writer.write(chunk.buffer)
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
            pendingDuration = session.duration
            mode = TranscriptMode.current
            recentSpeech = RollingTranscript()
            heardLine = ""
            audioProblem = nil
            // Saved in batches every 30 seconds while recording, not after every phrase.
            context.autosaveEnabled = false
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
        await audioWriter?.close()
        await transcriber?.finish()
        await eventsTask?.value
        finishSession()
    }

    #if DEBUG
    func debugSetVolatile(_ text: String) { volatileText = text; heardLine = text }

    /// Shows the recording state without a microphone, for screenshots.
    func debugSimulateRecording(in session: Session) {
        self.session = session
        timeOffset = 0
        runAccumulated = 754
        runStartedAt = .now
        level = 0.62
        volatileText = "But waiting on God means letting him be God, and trusting his timing"
        heardLine = volatileText
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
        // A file in the temporary folder, or (soak test) in Application Support/Transcribe/SoakTest.
        let name = arguments[index + 1]
        let soak = URL.applicationSupportDirectory.appending(path: "Transcribe/SoakTest/\(name)")
        let url = FileManager.default.fileExists(atPath: soak.path) ? soak : URL.temporaryDirectory.appending(path: name)
        let file = try AVAudioFile(forReading: url)
        let (stream, output) = AsyncStream.makeStream(of: AudioChunk.self)
        let box = UncheckedFile(file: file)
        // `-AudioSpeed 4` plays faster than real time; `-AudioSeconds 10800` loops the file to
        // make a long recording (the soak test).
        let requestedSpeed = UserDefaults.standard.double(forKey: "AudioSpeed")
        let speed = requestedSpeed > 0 ? requestedSpeed : 1
        let total = UserDefaults.standard.double(forKey: "AudioSeconds")
        debugFileTask = Task.detached {
            let file = box.file
            var played = 0.0
            while !Task.isCancelled {
                if file.framePosition >= file.length {
                    guard played < total else { break }
                    file.framePosition = 0
                }
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else { break }
                try? file.read(into: buffer, frameCount: 4096)
                let seconds = Double(buffer.frameLength) / buffer.format.sampleRate
                played += seconds
                output.yield(AudioChunk(buffer: buffer, level: 0.5))
                try? await Task.sleep(for: .seconds(seconds / speed))
                if total > 0, played >= total { break }
            }
            debugPlayedSeconds = played
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
    /// Set when the test file has finished playing (the soak test waits for it).
    nonisolated(unsafe) static var debugPlayedSeconds: Double?
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
            pendingVolatile = text
            publishSoon()
            if let session { onVolatile?(text, session) }
        case .status(let message):
            statusMessage = message
        case .finalized(let segment, let pending):
            append(segment, offset: offset)
            pendingVolatile = pending
            publishSoon()
            if let session, !pending.isEmpty { onVolatile?(pending, session) }
        }
    }

    private func append(_ segment: TranscribedSegment, offset: TimeInterval) {
        guard let session else { return }
        let start = timeOffset + offset + segment.start
        let end = timeOffset + offset + max(segment.end, segment.start)
        // In "Scripture and songs only" the phrase is a detached item: detection reads it, but
        // it's never added to the service, shown or saved.
        let item = TranscriptItem(kind: .segment, sortIndex: session.nextSortIndex, timestamp: start)
        item.text = segment.text
        item.endTimestamp = end
        if mode == .full {
            context.insert(item)
            item.session = session
        }
        recentSpeech.append(segment.text, end: end)
        latestAudioTime = max(latestAudioTime, offset + segment.end)
        pendingDuration = max(pendingDuration, end)
        onSegment?(item, session)
    }

    /// Shows the newest live text, at most four times a second.
    private func publishSoon() {
        guard publishTask == nil else { return }
        publishTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            self?.publishTask = nil
            self?.publishLiveText()
        }
    }

    private func publishLiveText() {
        if let pending = pendingVolatile {
            pendingVolatile = nil
            if volatileText != pending { volatileText = pending }
        }
        let line = RollingTranscript.lastWords(recentSpeech.text + " " + volatileText, count: 14)
        if heardLine != line { heardLine = line }
        if Date.now.timeIntervalSince(lastDurationWrite) >= 5 { writeDuration() }
    }

    private func writeDuration() {
        lastDurationWrite = .now
        guard let session, pendingDuration > session.duration else { return }
        session.duration = pendingDuration
        session.updatedAt = .now
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
        writeDuration()
        publishTask?.cancel()
        publishTask = nil
        pendingVolatile = nil
        audioWriter = nil
        recentSpeech = RollingTranscript()
        heardLine = ""
        Task { await capture.prepare() }
        autosaveTask?.cancel()
        tickTask?.cancel()
        session?.isRecording = false
        save()
        context.autosaveEnabled = true
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
        if state == .recording || state == .paused { writeDuration() }
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

/// The last 30 seconds of finished speech: what detection and the "Listening…" line need, and
/// all that "Scripture and songs only" keeps of the words.
struct RollingTranscript {
    static let window: TimeInterval = 30
    private(set) var pieces: [(end: TimeInterval, text: String)] = []

    mutating func append(_ text: String, end: TimeInterval) {
        pieces.append((end, text))
        pieces.removeAll { end - $0.end > Self.window }
    }

    var text: String { pieces.map(\.text).joined(separator: " ") }

    static func lastWords(_ text: String, count: Int) -> String {
        text.split(whereSeparator: \.isWhitespace).suffix(count).joined(separator: " ")
    }
}

/// Saves a recording's audio as AAC on a background queue, so a full transcript can be made later.
final class AudioFileWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Transcribe.audio-writer", qos: .utility)
    private let url: URL
    private var file: AVAudioFile?
    private var failed = false
    /// Called once, off the main thread, if the audio can't be written (e.g. the disk is full).
    var onFailure: (@Sendable (String) -> Void)?

    init(url: URL) { self.url = url }

    func write(_ buffer: AVAudioPCMBuffer) {
        queue.async { [self] in
            guard !failed else { return }
            do {
                if file == nil {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let channels = Int(buffer.format.channelCount)
                    let settings: [String: Any] = [
                        AVFormatIDKey: kAudioFormatMPEG4AAC,
                        AVSampleRateKey: buffer.format.sampleRate,
                        AVNumberOfChannelsKey: channels,
                        AVEncoderBitRateKey: 48_000 * channels,
                    ]
                    file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: buffer.format.commonFormat, interleaved: buffer.format.isInterleaved)
                }
                try file?.write(from: buffer)
            } catch {
                failed = true
                onFailure?(error.localizedDescription)
            }
        }
    }

    /// Finishes the file. Waits for audio already queued.
    func close() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                file?.close()
                file = nil
                done.resume()
            }
        }
    }
}
