import AudioCapture
import ScriptureDetector
import SectionClassifier
import UniformTypeIdentifiers
import Speech
import SwiftUI

struct SettingsView: View {
    @AppStorage(SettingsKey.settingsTab) private var tab = SettingsTab.general

    var body: some View {
        TabView(selection: $tab) {
            Tab("General", systemImage: "gearshape", value: SettingsTab.general) { GeneralSettings() }
            Tab("Scripture", systemImage: "book", value: SettingsTab.scripture) { ScriptureSettings() }
            Tab("Translations", systemImage: "books.vertical", value: SettingsTab.translations) { TranslationsSettings().frame(minHeight: 520) }
            Tab("Songs", systemImage: "music.note", value: SettingsTab.songs) { SongSettings() }
            Tab("Headers", systemImage: "list.bullet.indent", value: SettingsTab.headers) { HeaderSettings() }
        }
        .frame(width: 600)
        .scenePadding()
    }
}

private struct GeneralSettings: View {
    @AppStorage(SettingsKey.locale) private var localeID = Locale.current.identifier
    @AppStorage(SettingsKey.inputDeviceUID) private var inputUID = ""
    @AppStorage(SettingsKey.fontSize) private var fontSize = 16.0
    @AppStorage(SettingsKey.presentationFontSize) private var presentationFontSize = 44.0
    @State private var locales: [Locale] = []
    @State private var devices: [AudioInputDevice] = []

    var body: some View {
        Form {
            Section("Transcription") {
                Picker("Language", selection: $localeID) {
                    if !locales.contains(where: { $0.identifier == localeID }) {
                        Text(Locale.current.localizedString(forIdentifier: localeID) ?? localeID).tag(localeID)
                    }
                    ForEach(locales, id: \.identifier) { locale in
                        Text(Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier).tag(locale.identifier)
                    }
                }
                Text("Pick the variety of English your congregation speaks (for example English (Nigeria) or English (United Kingdom)). Transcription runs entirely on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Audio input", selection: $inputUID) {
                    Text("System Default").tag("")
                    ForEach(devices) { Text($0.name).tag($0.uid) }
                }
                Text("For the best results, use a feed from the sound desk through an audio interface rather than a laptop microphone.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Text Size") {
                Slider(value: $fontSize, in: 11...40, step: 1) { Text("Transcript") } minimumValueLabel: { Text("A").font(.caption) } maximumValueLabel: { Text("A").font(.title2) }
                Slider(value: $presentationFontSize, in: 20...120, step: 2) { Text("Presentation") } minimumValueLabel: { Text("A").font(.caption) } maximumValueLabel: { Text("A").font(.title2) }
            }
        }
        .formStyle(.grouped)
        .task {
            devices = AudioDeviceCatalog.inputDevices()
            let supported = await SpeechTranscriber.supportedLocales
            let list = supported.isEmpty ? Array(SFSpeechRecognizer.supportedLocales()) : supported
            locales = list.sorted { (Locale.current.localizedString(forIdentifier: $0.identifier) ?? "") < (Locale.current.localizedString(forIdentifier: $1.identifier) ?? "") }
        }
    }
}

private struct ScriptureSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.detectQuotes) private var detectQuotes = true
    @AppStorage(SettingsKey.rewriteReferences) private var rewriteReferences = true
    @AppStorage(SettingsKey.settingsTab) private var tab = SettingsTab.general

    var body: some View {
        Form {
            Section {
                Toggle("Recognize verses quoted without a reference", isOn: $detectQuotes)
                if detectQuotes && !model.scripture.isQuoteIndexReady {
                    Label("Preparing the verse index…", systemImage: "hourglass").font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Write references out in the transcript", isOn: $rewriteReferences)
                Text("“John 316” becomes “John 3:16”, “first Corinthians thirteen verse four” becomes “1 Corinthians 13:4”, and “the next verse” gets its reference. The original wording is kept.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text("When a reference is heard, Transcribe shows it in the default translation, then listens to the reading and switches to the version that matches best, unless the speaker names one.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Translations…") { tab = SettingsTab.translations }
            }
        }
        .formStyle(.grouped)
    }
}

private struct SongSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @AppStorage(SettingsKey.songThreshold) private var threshold = 0.55
    @AppStorage(SettingsKey.replaceSungText) private var replaceSungText = true

    var body: some View {
        Form {
            Section {
                LabeledContent("Detection sensitivity") {
                    Slider(value: $threshold, in: 0.4...0.8, step: 0.05) {
                        Text("Threshold")
                    } minimumValueLabel: { Text("More").font(.caption) } maximumValueLabel: { Text("Fewer").font(.caption) }
                }
                Text("Match needed to detect a song: \(Int(threshold * 100))%. Lower it if songs are missed; raise it if speech is mistaken for songs.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Replace sung transcription with the library lyrics", isOn: $replaceSungText)
                Text("The sung transcription is kept, folded under each song.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Songs in library", value: "\(model.songs.librarySize)")
                Button("Open Song Library…") { openWindow(id: WindowID.songLibrary) }
            }
        }
        .formStyle(.grouped)
    }
}

private struct HeaderSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.autoHeaders) private var autoHeaders = true

    var body: some View {
        Form {
            Section {
                Toggle("Add section headers automatically", isOn: $autoHeaders)
                Text("Welcome, Worship, Prayer, Announcements, Scripture Reading, Sermon, Offering, Altar Call and Closing headers are added as the service moves on. Edit them inline, or right-click to change, merge, or delete. Press ⌘H to add one yourself.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Apple Intelligence") {
                switch model.sections.status {
                case .available:
                    Label("On-device model available. Headers, sermon titles and summaries use it.", systemImage: "checkmark.seal")
                case .unavailable(let reason):
                    Label(reason, systemImage: "exclamationmark.triangle")
                    Button("Open Apple Intelligence Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")!)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.sections.refreshStatus() }
    }
}
