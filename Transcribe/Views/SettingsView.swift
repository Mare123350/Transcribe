import AudioCapture
import ScriptureDetector
import SectionClassifier
import UniformTypeIdentifiers
import Speech
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Scripture", systemImage: "book") { ScriptureSettings() }
            Tab("Songs", systemImage: "music.note") { SongSettings() }
            Tab("Headers", systemImage: "list.bullet.indent") { HeaderSettings() }
        }
        .frame(width: 560)
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
    @AppStorage(SettingsKey.defaultTranslation) private var defaultTranslation = "KJV"
    @AppStorage(SettingsKey.detectQuotes) private var detectQuotes = true
    @State private var importing = false
    @State private var importError: String?

    var body: some View {
        Form {
            Section {
                Picker("Default version", selection: $defaultTranslation) {
                    ForEach(model.scripture.translations) { Text("\($0.abbreviation) — \($0.name)").tag($0.abbreviation) }
                }
                Text("Shown first when a reference is heard. Transcribe then listens to the reading and switches to the version that matches best, unless the speaker names one.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Recognize verses quoted without a reference", isOn: $detectQuotes)
                if detectQuotes && !model.scripture.isQuoteIndexReady {
                    Label("Preparing the verse index…", systemImage: "hourglass").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                ForEach(model.scripture.translations) { translation in
                    HStack {
                        VStack(alignment: .leading) {
                            Text("\(translation.abbreviation) — \(translation.name)")
                            Text(translation.isBundled ? "Bundled · \(translation.license)" : "Imported · \(translation.license)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !translation.isBundled {
                            Button("Remove", role: .destructive) { Task { await model.scripture.removeTranslation(translation) } }
                        }
                    }
                }
            } header: {
                Text("Installed Translations")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("KJV, WEB, BSB, ASV and YLT are public domain and included. Other versions such as NIV, ESV, NKJV and NLT are copyrighted: import them only if your church is licensed to use them, as a .sqlite or .json file in the format described in docs/TRANSLATION_FORMAT.md.")
                    Button("Import Translation…") { importing = true }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json, UTType(filenameExtension: "sqlite") ?? .database, .database]) { result in
            guard case .success(let url) = result else { return }
            Task {
                do { try await model.scripture.importTranslation(from: url) }
                catch { importError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
            }
        }
        .alert("Couldn't Import", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
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
