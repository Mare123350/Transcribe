import ScriptureDetector
import SwiftUI
import UniformTypeIdentifiers

enum SettingsTab {
    static let general = "general"
    static let scripture = "scripture"
    static let translations = "translations"
    static let songs = "songs"
    static let output = "output"
    static let headers = "headers"
}

/// Settings › Translations: what's installed, the default and fallback order, online providers,
/// and how to get versions that can't be bundled.
struct TranslationsSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.defaultTranslation) private var defaultTranslation = "KJV"
    @AppStorage(SettingsKey.translationOrder) private var orderSetting = ""
    @State private var importing = false
    @State private var importError: String?
    @State private var parsed: ParsedTranslation?
    @State private var reading = false

    private var scripture: ScriptureService { model.scripture }

    /// The fallback order, completed with every available version not yet in it.
    private var order: [String] {
        let saved = orderSetting.split(separator: ",").map(String.init)
        let all = scripture.allVersionNames.map(\.abbreviation)
        return saved.filter(all.contains) + all.filter { !saved.contains($0) }
    }

    var body: some View {
        Form {
            Section {
                Picker("Default translation", selection: $defaultTranslation) {
                    ForEach(scripture.translations) { Text("\($0.abbreviation) — \($0.name)").tag($0.abbreviation) }
                }
                Text("Shown when a reference is heard and no version is named, and whenever a requested version isn't available (for example “NIV requested, showing \(defaultTranslation)”).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                ForEach(Array(order.enumerated()), id: \.element) { index, abbreviation in
                    HStack {
                        Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary).frame(width: 22, alignment: .trailing)
                        Text(abbreviation).fontWeight(abbreviation == defaultTranslation ? .semibold : .regular)
                        if let version = scripture.allVersionNames.first(where: { $0.abbreviation == abbreviation }) {
                            Text(version.name).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button { move(abbreviation, by: -1) } label: { Label("Move Up", systemImage: "chevron.up").labelStyle(.iconOnly) }
                            .buttonStyle(.borderless).disabled(index == 0)
                            .help("Try \(abbreviation) earlier")
                        Button { move(abbreviation, by: 1) } label: { Label("Move Down", systemImage: "chevron.down").labelStyle(.iconOnly) }
                            .buttonStyle(.borderless).disabled(index == order.count - 1)
                            .help("Try \(abbreviation) later")
                    }
                }
            } header: {
                Text("Fallback Order")
            } footer: {
                Text("If the default doesn't have a passage (for example a New Testament–only import), these are tried in order.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                ForEach(scripture.translations) { translation in
                    HStack {
                        VStack(alignment: .leading) {
                            Text("\(translation.abbreviation) — \(translation.name)")
                            Text(translation.isBundled ? "Included · \(translation.license)" : "Imported · \(translation.license)")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        if !translation.isBundled {
                            Button("Remove", role: .destructive) { Task { await scripture.removeTranslation(translation) } }
                        }
                    }
                }
            } header: {
                Text("Installed")
            } footer: {
                HStack {
                    Text("Import a licensed copy as OSIS, USFM (a file or a folder of books), USX, Zefania XML, or JSON.")
                    Spacer()
                    Button(reading ? "Reading…" : "Import Translation…") { importing = true }.disabled(reading)
                }
                .font(.caption).foregroundStyle(.secondary)
            }

            ProviderSection(provider: .esv)
            ProviderSection(provider: .apiBible)

            Section {
                ForEach(TranslationResolver.copyrighted, id: \.abbreviation) { version in
                    let installed = scripture.allVersionNames.contains { $0.abbreviation.caseInsensitiveCompare(version.abbreviation) == .orderedSame }
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading) {
                            Text("\(version.abbreviation) — \(version.name)")
                            Text(installed ? "Available" : "Import a licensed copy, or use \(version.provider ?? "an online provider").")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if installed { Image(systemName: "checkmark.circle.fill").foregroundStyle(Design.Palette.good) }
                    }
                }
            } header: {
                Text("Copyrighted Versions")
            } footer: {
                Text("These can't be included with Transcribe. Use them only if your church is licensed to.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item, .folder], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            reading = true
            Task {
                defer { reading = false }
                do { parsed = try await scripture.parseImport(urls) }
                catch { importError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
            }
        }
        .sheet(isPresented: Binding(get: { parsed != nil }, set: { if !$0 { parsed = nil } })) {
            if let parsed { ImportTranslationSheet(parsed: parsed) }
        }
        .alert("Couldn't Import", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
        .task { await scripture.refreshOnline() }
    }

    private func move(_ abbreviation: String, by delta: Int) {
        var list = order
        guard let index = list.firstIndex(of: abbreviation), list.indices.contains(index + delta) else { return }
        list.swapAt(index, index + delta)
        orderSetting = list.joined(separator: ",")
    }
}

/// Shows what was found in the file and asks for the name and licence before installing.
private struct ImportTranslationSheet: View {
    let parsed: ParsedTranslation
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var abbreviation = ""
    @State private var name = ""
    @State private var license = ""
    @State private var licensed = false
    @State private var error: String?
    @State private var installing = false

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.l) {
            Text("Import Translation").font(.title2.bold())
            Grid(alignment: .leading, verticalSpacing: 6) {
                GridRow { Text("Format").foregroundStyle(.secondary); Text(parsed.format.rawValue) }
                GridRow { Text("Contents").foregroundStyle(.secondary); Text("\(parsed.verses.count.formatted()) verses in \(parsed.bookCount) books · \(testaments)") }
            }
            if !parsed.warnings.isEmpty {
                VStack(alignment: .leading, spacing: Design.Space.xxs) {
                    ForEach(parsed.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.caption) }
                }
                .foregroundStyle(.secondary)
            }
            Form {
                TextField("Abbreviation", text: $abbreviation, prompt: Text("NIV"))
                TextField("Name", text: $name, prompt: Text("New International Version"))
                TextField("Licence", text: $license, prompt: Text("Licensed to Grace Church"))
                Toggle("Our church is licensed to use this translation", isOn: $licensed)
            }
            .formStyle(.grouped)
            if let error { Text(error).foregroundStyle(Design.Palette.error).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(installing ? "Installing…" : "Install") { install() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!licensed || abbreviation.trimmingCharacters(in: .whitespaces).isEmpty || installing)
            }
        }
        .sheetLayout()
        .onAppear {
            abbreviation = parsed.abbreviation
            name = parsed.name
            license = parsed.license
        }
    }

    private var testaments: String {
        switch (parsed.hasOldTestament, parsed.hasNewTestament) {
        case (true, true): "Old and New Testaments"
        case (true, false): "Old Testament only"
        case (false, true): "New Testament only"
        default: "no canonical books"
        }
    }

    private func install() {
        installing = true
        Task {
            defer { installing = false }
            do {
                try await model.scripture.install(parsed, abbreviation: abbreviation, name: name, license: license)
                dismiss()
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

/// One online provider: the user's key (kept in the Keychain) and, for API.Bible, which versions to use.
private struct ProviderSection: View {
    let provider: OnlineProviderID
    @Environment(AppModel.self) private var model
    @State private var key = ""
    @State private var hasKey = false
    @State private var checking = false
    @State private var message: String?
    @State private var available: [OnlineVersion] = []
    @State private var chosen: Set<String> = []

    var body: some View {
        Section {
            if hasKey {
                LabeledContent("Key") {
                    HStack {
                        Label("Saved in the Keychain", systemImage: "key.fill").foregroundStyle(.secondary)
                        Button("Remove", role: .destructive) {
                            Task {
                                await model.scripture.removeKey(provider)
                                hasKey = false
                                available = []
                                chosen = []
                            }
                        }
                    }
                }
            } else {
                HStack {
                    SecureField("API key", text: $key)
                    Button(checking ? "Checking…" : "Connect") { connect() }
                        .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || checking)
                }
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }

            if provider == .apiBible && hasKey {
                if available.isEmpty {
                    Button("Choose Versions…") { connect(reusingSavedKey: true) }
                } else {
                    ForEach(available) { version in
                        Toggle(isOn: Binding(
                            get: { chosen.contains(version.remoteID) },
                            set: { on in
                                if on { chosen.insert(version.remoteID) } else { chosen.remove(version.remoteID) }
                                model.scripture.setAPIBibleVersions(available.filter { chosen.contains($0.remoteID) })
                            }
                        )) {
                            Text("\(version.abbreviation) — \(version.name)")
                        }
                    }
                }
            }
        } header: {
            Text(provider.displayName)
        } footer: {
            VStack(alignment: .leading, spacing: Design.Space.xs) {
                switch provider {
                case .esv:
                    Text("Free for non-commercial use with your own key. Up to 500 verses are kept on this Mac, as Crossway's terms allow, and the ESV copyright notice is shown with each passage.")
                case .apiBible:
                    Text("Your key decides which versions you can use (licensed versions such as NIV need approval from API.Bible). Fetched passages are refreshed at least every 30 days, and each display is counted anonymously as API.Bible requires.")
                }
                Link("Get a key", destination: provider.signUpURL)
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear {
            hasKey = model.scripture.hasKey(provider)
            if provider == .apiBible {
                let stored = ScriptureService.storedAPIBibleVersions
                available = stored
                chosen = Set(stored.map(\.remoteID))
            }
        }
    }

    private func connect(reusingSavedKey: Bool = false) {
        checking = true
        message = nil
        Task {
            defer { checking = false }
            do {
                let keyToUse = reusingSavedKey ? (KeychainCredentialStore().key(for: provider) ?? "") : key
                let versions = try await model.scripture.saveKey(keyToUse, for: provider)
                key = ""
                hasKey = true
                if provider == .apiBible {
                    let previous = Set(ScriptureService.storedAPIBibleVersions.map(\.remoteID))
                    available = versions
                    chosen = previous
                    message = "Connected. \(versions.count) English versions are available to this key; turn on the ones you want."
                } else {
                    message = "Connected. ESV is available."
                }
            } catch {
                message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
