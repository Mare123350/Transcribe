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
    var problem: PermissionProblem?
    var errorMessage: String?

    /// Called for each finalized segment, after it has been added to the session.
    var onSegment: ((TranscriptItem, Session) -> Void)?
    /// Called about once a second while recording, with the current recording time.
    var onTick: ((TimeInterval, Session) -> Void)?

    private let context: ModelContext
    private let capture = AudioCaptureEngine()
    private var transcriber: (any LiveTranscriber)?
    private var eventsTask: Task<Void, Never>?
    private var forwardTask: Task<Void, Never>?
    private var autosaveTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    /// Recording time already in the session before this run started, so timestamps keep counting.
    private var timeOffset: TimeInterval = 0
    private var latestAudioTime: TimeInterval = 0

    static let autosaveInterval: Duration = .seconds(30)

    init(context: ModelContext) {
        self.context = context
    }

    var isActive: Bool { state == .recording || state == .paused || state == .starting }

    /// Current position in the recording, for timestamping things inserted by hand.
    var currentTime: TimeInterval { timeOffset + latestAudioTime }

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
        state = .starting
        errorMessage = nil
        problem = nil

        guard await AudioCaptureEngine.requestMicrophoneAccess() else {
            problem = .microphone
            state = .idle
            return
        }

        let defaults = UserDefaults.standard
        let localeID = defaults.string(forKey: SettingsKey.locale) ?? Locale.current.identifier
        let deviceUID = defaults.string(forKey: SettingsKey.inputDeviceUID) ?? ""
        let deviceID = deviceUID.isEmpty ? nil : AudioDeviceCatalog.device(withUID: deviceUID)?.id

        do {
            let transcriber = try await TranscriberFactory.make(locale: Locale(identifier: localeID))
            let captured = try await capture.start(deviceID: deviceID)
            let (audio, audioOutput) = AsyncStream.makeStream(of: AudioChunk.self, bufferingPolicy: .bufferingNewest(256))
            forwardTask = Task.detached { [weak self] in
                var lastLevel = ContinuousClock.now
                for await chunk in captured {
                    audioOutput.yield(chunk)
                    let now = ContinuousClock.now
                    if now - lastLevel > .milliseconds(80) {
                        lastLevel = now
                        let level = chunk.level
                        await MainActor.run { self?.level = level }
                    }
                }
                audioOutput.finish()
            }

            let events = try await transcriber.start(audio: audio)
            self.transcriber = transcriber
            self.engine = transcriber.engine
            self.session = session
            timeOffset = session.duration
            latestAudioTime = 0
            session.isRecording = true
            session.localeIdentifier = localeID
            session.engineName = transcriber.engine.rawValue
            save()

            eventsTask = Task { [weak self] in
                do {
                    for try await event in events {
                        self?.handle(event)
                    }
                } catch {
                    self?.errorMessage = Self.describe(error)
                }
                self?.didFinishEvents()
            }
            startAutosave()
            startTicks()
            state = .recording
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
        state = .paused
        save()
    }

    func resume() async {
        guard state == .paused else { return }
        do {
            try await capture.resume()
            state = .recording
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    func stop() async {
        guard state == .recording || state == .paused else { return }
        state = .stopping
        await capture.stop()
        await forwardTask?.value
        await transcriber?.finish()
        await eventsTask?.value
        finishSession()
    }

    #if DEBUG
    func debugSetVolatile(_ text: String) { volatileText = text }
    #endif

    // MARK: - Events

    private func handle(_ event: TranscriptionEvent) {
        switch event {
        case .volatile(let text):
            volatileText = text
        case .status(let message):
            statusMessage = message
        case .finalized(let segment):
            append(segment)
        }
    }

    private func append(_ segment: TranscribedSegment) {
        guard let session else { return }
        let item = TranscriptItem(kind: .segment, sortIndex: session.nextSortIndex, timestamp: timeOffset + segment.start)
        item.text = segment.text
        item.endTimestamp = timeOffset + max(segment.end, segment.start)
        context.insert(item)
        item.session = session
        latestAudioTime = max(latestAudioTime, segment.end)
        session.duration = max(session.duration, item.endTimestamp)
        session.updatedAt = .now
        volatileText = ""
        onSegment?(item, session)
    }

    private func didFinishEvents() {
        // The transcriber stopped on its own (e.g. an error). Tidy up as if Stop was pressed.
        if state == .recording || state == .paused {
            Task { await self.stop() }
        }
    }

    private func finishSession() {
        autosaveTask?.cancel()
        tickTask?.cancel()
        session?.isRecording = false
        save()
        transcriber = nil
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
