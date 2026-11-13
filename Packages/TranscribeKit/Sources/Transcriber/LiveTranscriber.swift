import AudioCapture
import Foundation

/// A finished piece of transcript, with its position in the recording's audio timeline.
public struct TranscribedSegment: Sendable, Equatable {
    public let text: String
    /// Seconds of recorded audio before this segment began (paused time doesn't count).
    public let start: TimeInterval
    public let end: TimeInterval

    public init(text: String, start: TimeInterval, end: TimeInterval) {
        self.text = text
        self.start = start
        self.end = end
    }
}

public enum TranscriptionEvent: Sendable {
    /// In-progress text that may still change. Replaces the previous volatile text.
    case volatile(String)
    case finalized(TranscribedSegment)
    /// Something worth telling the operator, e.g. "Downloading the speech model…".
    case status(String)
}

public enum TranscriberEngine: String, Sendable {
    case speechAnalyzer = "SpeechAnalyzer"
    case onDeviceRecognizer = "On-device SFSpeechRecognizer"
}

public enum TranscriberError: LocalizedError, Sendable, Equatable {
    case unsupportedLocale(String)
    case onDeviceUnavailable
    case speechPermissionDenied
    case noAudioFormat

    public var errorDescription: String? {
        switch self {
        case .unsupportedLocale(let id):
            "On-device transcription isn't available for “\(id)”. Pick another language in Settings."
        case .onDeviceUnavailable:
            "This Mac can't transcribe on-device for the selected language."
        case .speechPermissionDenied:
            "Transcribe doesn't have permission to use speech recognition."
        case .noAudioFormat:
            "The speech model couldn't accept audio from this input."
        }
    }
}

/// Turns a stream of audio into transcript events, entirely on-device.
public protocol LiveTranscriber: Actor {
    nonisolated var engine: TranscriberEngine { get }
    /// Starts consuming `audio`. The returned stream ends after `audio` ends and remaining text is flushed.
    func start(audio: AsyncStream<AudioChunk>) async throws -> AsyncThrowingStream<TranscriptionEvent, Error>
    /// Waits for the remaining audio to be transcribed. Call after ending the audio stream.
    func finish() async
}

public enum TranscriberFactory {
    /// Prefers SpeechAnalyzer; falls back to the on-device SFSpeechRecognizer when SpeechTranscriber
    /// doesn't support this Mac or language.
    public static func make(locale: Locale) async throws -> any LiveTranscriber {
        if let supported = await AnalyzerTranscriber.supportedLocale(for: locale) {
            return AnalyzerTranscriber(locale: supported)
        }
        return try OnDeviceRecognizerTranscriber(locale: locale)
    }
}
