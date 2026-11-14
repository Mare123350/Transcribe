@preconcurrency import AVFoundation
import AudioCapture
import Foundation
@preconcurrency import Speech

/// Fallback transcription with SFSpeechRecognizer, forced on-device. A recognition request
/// keeps growing until it ends, so this rotates to a fresh request after each pause in speech
/// (or every 50 seconds) and reports the finished request as a final segment.
public actor OnDeviceRecognizerTranscriber: LiveTranscriber {
    public nonisolated let engine = TranscriberEngine.onDeviceRecognizer
    private let recognizer: SFSpeechRecognizer

    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var output: AsyncThrowingStream<TranscriptionEvent, Error>.Continuation?
    private var feedTask: Task<Void, Never>?

    private var audioSeconds: TimeInterval = 0
    private var requestStart: TimeInterval = 0
    private var partialText = ""
    private var lastPartialChange: TimeInterval = 0
    private var pendingTasks = 0

    public init(locale: Locale) throws {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw TranscriberError.unsupportedLocale(locale.identifier)
        }
        guard recognizer.supportsOnDeviceRecognition else { throw TranscriberError.onDeviceUnavailable }
        self.recognizer = recognizer
    }

    public static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    public func start(audio: AsyncStream<AudioChunk>) async throws -> AsyncThrowingStream<TranscriptionEvent, Error> {
        var status = SFSpeechRecognizer.authorizationStatus()
        if status == .notDetermined { status = await Self.requestAuthorization() }
        guard status == .authorized else { throw TranscriberError.speechPermissionDenied }

        let (events, output) = AsyncThrowingStream.makeStream(of: TranscriptionEvent.self)
        self.output = output
        beginRequest()

        feedTask = Task {
            for await chunk in audio {
                self.append(chunk)
            }
            self.endRequest()
        }
        return events
    }

    public func finish() async {
        await feedTask?.value
        // Give the last request a moment to deliver its final result.
        for _ in 0..<40 where pendingTasks > 0 {
            try? await Task.sleep(for: .milliseconds(100))
        }
        output?.finish()
        output = nil
    }

    private func append(_ chunk: AudioChunk) {
        request?.append(chunk.buffer)
        audioSeconds += Double(chunk.buffer.frameLength) / chunk.buffer.format.sampleRate

        let quietFor = audioSeconds - lastPartialChange
        let requestLength = audioSeconds - requestStart
        if !partialText.isEmpty && (quietFor > 1.5 || requestLength > 50) {
            endRequest()
            beginRequest()
        }
    }

    private func beginRequest() {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        self.request = request
        requestStart = audioSeconds
        lastPartialChange = audioSeconds
        partialText = ""
        pendingTasks += 1

        let offset = requestStart
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString ?? ""
            let isFinal = result?.isFinal ?? false
            let duration = result?.bestTranscription.segments.last.map { $0.timestamp + $0.duration } ?? 0
            let failed = error != nil
            Task { await self?.handle(text: text, isFinal: isFinal, failed: failed, offset: offset, duration: duration) }
        }
    }

    private func endRequest() {
        request?.endAudio()
        request = nil
    }

    private func handle(text: String, isFinal: Bool, failed: Bool, offset: TimeInterval, duration: TimeInterval) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isFinal || failed {
            pendingTasks = max(0, pendingTasks - 1)
            // An older request finishing while the next one is already hearing words: keep those.
            let pending = offset == requestStart ? "" : partialText
            if !trimmed.isEmpty {
                output?.yield(.finalized(TranscribedSegment(text: trimmed, start: offset, end: offset + duration), pending: pending))
            } else {
                output?.yield(.volatile(pending))
            }
            return
        }
        guard offset == requestStart else { return }
        if trimmed != partialText {
            partialText = trimmed
            lastPartialChange = audioSeconds
            output?.yield(.volatile(trimmed))
        }
    }
}
