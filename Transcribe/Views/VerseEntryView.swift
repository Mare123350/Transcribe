import ScriptureDetector
import SwiftUI

/// Type a verse to show it: "jn 3 16", "ps 23", "rom 8:28-30 niv". Return puts it in Preview,
/// Shift-Return sends it to the screen, Option-Return adds it to the transcript.
struct VerseEntryView: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var chosenVersion = ""
    @State private var verseText = ""
    @FocusState private var focused: Bool

    private var versions: [String] { model.scripture.allVersionNames.map(\.abbreviation) }
    private var parsed: (reference: DetectedReference, version: String?)? { ReferenceParser.parseEntry(text, versions: versions) }
    /// Only a specific verse or range is shown: "gen 1" alone would put the whole chapter up.
    private var exact: BibleReference? {
        guard let reference = parsed?.reference.reference, reference.verseStart != nil else { return nil }
        return reference
    }
    private var version: String {
        parsed?.version ?? (chosenVersion.isEmpty ? model.scripture.defaultAbbreviation : chosenVersion)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Verse, e.g. jn 3 16", text: $text)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { act(.preview) }
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) { act(.send); return .handled }
                        if press.modifiers.contains(.option) { act(.transcript); return .handled }
                        return .ignored
                    }
                    .onExitCommand { text = "" }
                Menu(version) {
                    ForEach(model.scripture.allVersionNames, id: \.abbreviation) { option in
                        Button("\(option.abbreviation) — \(option.name)") { chosenVersion = option.abbreviation }
                    }
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .fixedSize()
                .help("Version (or type it after the reference, e.g. “jn 3 16 niv”)")
            }
            .padding(6)
            .background(.background, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(focused ? Color.accentColor : Color.secondary.opacity(0.3)))

            if let parsed, exact == nil {
                Text("Add a verse number, e.g. “\(parsed.reference.reference.description) 1”.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let parsed {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(parsed.reference.reference.description) · \(version)").font(.caption.weight(.semibold))
                    Text(verseText.isEmpty ? "Not in \(version)." : verseText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }
                HStack {
                    Button("Preview") { act(.preview) }.help("Show in Preview (↩)")
                    Button("Send") { act(.send) }.buttonStyle(.borderedProminent).help("Send to the screen (⇧↩)")
                    Button("Add to Transcript") { act(.transcript) }
                        .disabled(model.selectedSession == nil)
                        .help("Add a verse card to the transcript (⌥↩)")
                }
                .controlSize(.small)
                .disabled(verseText.isEmpty)
            } else if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("Type a book, chapter and verse, like “jn 3 16” or “1 cor 13 4-7”.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if !model.scripture.recentVerses.isEmpty {
                DisclosureGroup("Recent") {
                    ForEach(model.scripture.recentVerses.prefix(8)) { recent in
                        Button {
                            Task { await model.output.previewOnly(.passage(recent.reference, version: recent.version)) }
                        } label: {
                            HStack {
                                Text(recent.reference.description)
                                Spacer()
                                Text(recent.version).foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .help("Show in Preview")
                        .contextMenu {
                            Button("Send to Screen") { Task { await model.output.send(.passage(recent.reference, version: recent.version)) } }
                            Button("Show in Preview") { Task { await model.output.previewOnly(.passage(recent.reference, version: recent.version)) } }
                            Button("Add to Transcript") { insert(recent.reference, version: recent.version) }
                                .disabled(model.selectedSession == nil)
                            Divider()
                            Button("Remove from Recent") { model.scripture.forget(recent) }
                        }
                    }
                }
                .font(.caption)
            }
        }
        .task(id: "\(text)|\(version)") {
            guard let exact else { verseText = ""; return }
            verseText = await model.scripture.text(of: exact, abbreviation: version) ?? ""
        }
        .onChange(of: model.verseEntryFocusRequest) { focused = true }
    }

    private enum Action { case preview, send, transcript }

    private func act(_ action: Action) {
        guard let reference = exact, !verseText.isEmpty else { return }
        let version = version
        model.scripture.remember(reference, version: version)
        switch action {
        case .preview: Task { await model.output.previewOnly(.passage(reference, version: version)) }
        case .send: Task { await model.output.send(.passage(reference, version: version)) }
        case .transcript: insert(reference, version: version)
        }
        text = ""
    }

    private func insert(_ reference: BibleReference, version: String) {
        guard let session = model.selectedSession else { return }
        let time = model.recorder.session === session ? model.recorder.currentTime : session.duration
        Task { await model.scripture.insertManual(reference, abbreviation: version, in: session, at: time) }
    }
}
