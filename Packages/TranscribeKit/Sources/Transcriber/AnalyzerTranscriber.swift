@preconcurrency import AVFoundation
import AudioCapture
import CoreMedia
import Foundation
@preconcurrency import Speech

/// Live transcription with SpeechAnalyzer + SpeechTranscriber (macOS 26). Runs on-device; the
/// language model is downloaded once by the system and shared between apps.
public actor AnalyzerTranscriber: LiveTranscriber {
    public nonisolated let engine = TranscriberEngine.speechAnalyzer
    private let locale: Locale
    private var analyzer: SpeechAnalyzer?
    private var feedTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?

    public init(locale: Locale) {
        self.locale = locale
    }

    public static func supportedLocale(for locale: Locale) async -> Locale? {
        if let cached = await LocaleCache.shared.value(for: locale.identifier) { return cached }
        guard SpeechTranscriber.isAvailable else { return nil }
        let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
        await LocaleCache.shared.store(supported, for: locale.identifier)
        return supported
    }

    /// Looks up the model for `locale` ahead of time so pressing Record is quick.
    public static func prewarm(locale: Locale) async {
        _ = await supportedLocale(for: locale)
    }

    public func start(audio: AsyncStream<AudioChunk>) async throws -> AsyncThrowingStream<TranscriptionEvent, Error> {
        let (events, output) = AsyncThrowingStream.makeStream(of: TranscriptionEvent.self)

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.audioTimeRange]
        )

        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            output.yield(.status("Downloading the on-device speech model…"))
            try await request.downloadAndInstall()
            output.yield(.status(""))
        }

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TranscriberError.noAudioFormat
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (inputs, inputBuilder) = AsyncStream.makeStream(of: AnalyzerInput.self)
        try await analyzer.start(inputSequence: inputs)
        self.analyzer = analyzer

        resultsTask = Task {
            // The newest in-progress text and where it starts in the audio. A final result for
            // earlier audio can arrive after in-progress text for later audio; that text is kept.
            var pending = ""
            var pendingStart = 0.0
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    let start = result.range.start.seconds.isFinite ? result.range.start.seconds : 0
                    let end = result.range.end.seconds.isFinite ? result.range.end.seconds : start
                    if result.isFinal {
                        if pendingStart < end - 0.05 { pending = "" }
                        guard !text.isEmpty else {
                            if pending.isEmpty { output.yield(.volatile("")) }
                            continue
                        }
                        output.yield(.finalized(TranscribedSegment(text: text, start: start, end: end), pending: pending))
                    } else {
                        pending = text
                        pendingStart = start
                        output.yield(.volatile(text))
                    }
                }
                output.finish()
            } catch {
                output.finish(throwing: error)
            }
        }

        feedTask = Task.detached {
            let converter = BufferConverter(outputFormat: format)
            for await chunk in audio {
                if let converted = converter.convert(chunk.buffer) {
                    inputBuilder.yield(AnalyzerInput(buffer: converted))
                }
            }
            inputBuilder.finish()
        }

        return events
    }

    public func finish() async {
        await feedTask?.value
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        await resultsTask?.value
        analyzer = nil
    }
}

/// Supported-locale answers, which don't change while the app runs.
actor LocaleCache {
    static let shared = LocaleCache()
    private var values: [String: Locale?] = [:]

    func value(for identifier: String) -> Locale?? { values[identifier] }
    func store(_ locale: Locale?, for identifier: String) { values[identifier] = locale }
}

extension AnalyzerTranscriber {
    /// Transcribes a saved recording as fast as the Mac allows, reporting each finished phrase with
    /// its time in the file. Used to make the full transcript of a service recorded with
    /// "Scripture and songs only".
    public static func transcribeFile(_ url: URL, locale: Locale, onSegment: @escaping @Sendable (TranscribedSegment) async -> Void) async throws {
        guard let supported = await supportedLocale(for: locale) else {
            throw TranscriberError.unsupportedLocale(locale.identifier)
        }
        let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let file = try AVAudioFile(forReading: url)
        let results = Task {
            for try await result in transcriber.results where result.isFinal {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let start = result.range.start.seconds.isFinite ? result.range.start.seconds : 0
                let end = result.range.end.seconds.isFinite ? result.range.end.seconds : start
                await onSegment(TranscribedSegment(text: text, start: start, end: end))
            }
        }
        let analyzer = try await SpeechAnalyzer(inputAudioFile: file, modules: [transcriber], finishAfterFile: true)
        try await withTaskCancellationHandler {
            try await results.value
        } onCancel: {
            results.cancel()
            Task { await analyzer.cancelAndFinishNow() }
        }
    }
}
