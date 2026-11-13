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
        guard SpeechTranscriber.isAvailable else { return nil }
        return await SpeechTranscriber.supportedLocale(equivalentTo: locale)
    }

    public func start(audio: AsyncStream<AudioChunk>) async throws -> AsyncThrowingStream<TranscriptionEvent, Error> {
        let (events, output) = AsyncThrowingStream.makeStream(of: TranscriptionEvent.self)

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
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
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    if result.isFinal {
                        guard !text.isEmpty else { continue }
                        let start = result.range.start.seconds
                        let end = result.range.end.seconds
                        output.yield(.finalized(TranscribedSegment(
                            text: text,
                            start: start.isFinite ? start : 0,
                            end: end.isFinite ? end : 0
                        )))
                    } else {
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
