import AppKit
import Foundation

enum SettingsKey {
    static let fontSize = "transcriptFontSize"
    static let locale = "transcriptionLocale"
    static let inputDeviceUID = "inputDeviceUID"
    static let defaultTranslation = "defaultTranslation"
    static let songThreshold = "songMatchThreshold"
    static let autoHeaders = "automaticHeaders"
    static let detectQuotes = "detectQuotedVerses"
    static let replaceSungText = "replaceSungTextWithLyrics"
    static let presentationFontSize = "presentationFontSize"
    /// Comma-separated abbreviations tried after the default when a passage is missing.
    static let translationOrder = "translationFallbackOrder"
    /// JSON list of API.Bible versions the user chose.
    static let apiBibleVersions = "apiBibleVersions"
    /// Anonymous id for API.Bible usage reporting.
    static let providerDeviceID = "bibleProviderDeviceID"
    static let settingsTab = "settingsTab"
    static let rewriteReferences = "rewriteReferencesInTranscript"
}

/// A permission the app needs but doesn't have, with guidance and a shortcut to System Settings.
enum PermissionProblem: Identifiable, Equatable {
    case microphone
    case speechRecognition

    var id: Self { self }

    var title: String {
        switch self {
        case .microphone: "Microphone access is off"
        case .speechRecognition: "Speech recognition is off"
        }
    }

    var message: String {
        switch self {
        case .microphone:
            "Transcribe needs the microphone to hear the service. Open System Settings › Privacy & Security › Microphone, turn on Transcribe, then press Record again. Audio stays on this Mac."
        case .speechRecognition:
            "On this Mac, Transcribe uses Apple's on-device speech recognizer. Open System Settings › Privacy & Security › Speech Recognition, turn on Transcribe, then press Record again."
        }
    }

    var settingsURL: URL {
        switch self {
        case .microphone: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        case .speechRecognition: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")!
        }
    }

    func openSettings() {
        NSWorkspace.shared.open(settingsURL)
    }
}

enum TimeFormat {
    /// 75 -> "1:15", 3725 -> "1:02:05"
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
