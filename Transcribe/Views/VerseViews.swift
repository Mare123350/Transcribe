import ScriptureDetector
import SwiftUI

/// A detected verse: reference, version, and the canonical text, with what was actually said
/// tucked underneath.
struct VerseCalloutView: View {
    @Bindable var item: TranscriptItem
    let session: Session
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.fontSize) private var fontSize = 16.0
    @State private var showSpoken = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            TimestampLabel(seconds: item.timestamp)
            VStack(alignment: .leading, spacing: 8) {
                header
                if needsConfirmation { confirmationBar }

                if item.verseText.isEmpty {
                    Text(item.spokenText.isEmpty ? "Waiting for the passage…" : item.spokenText)
                        .font(.system(.body, design: .serif))
                        .foregroundStyle(.secondary)
                        .italic()
                    if item.versionNamedBySpeaker {
                        Text("\(item.versionAbbreviation) isn't installed, so the spoken words are shown. Import it in Settings › Translations if your church is licensed to use it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(item.verseText)
                        .font(.system(size: fontSize * 1.05, design: .serif))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !item.spokenText.isEmpty && !item.verseText.isEmpty {
                    DisclosureGroup(isExpanded: $showSpoken) {
                        Text(item.spokenText)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Text("Spoken transcription").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .leading) {
                UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10).fill(.orange).frame(width: 4)
            }
        }
        .contextMenu { menuItems }
    }

    private var needsConfirmation: Bool {
        item.status != .confirmed && (item.referenceConfidence < 0.75 || item.verseSource == .quote)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: item.verseSource == .quote ? "quote.opening" : "book.closed.fill")
                .foregroundStyle(.orange)
            Text(item.reference)
                .font(.headline)
            Text("—").foregroundStyle(.tertiary)
            Menu {
                versionMenu
            } label: {
                Text(versionLabel)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()
            .help("Change the version")
            if !item.versionSettled && item.verseSource == .reference && model.recorder.isActive {
                ProgressView().controlSize(.mini).help("Listening to identify the version")
            }
            Spacer()
        }
    }

    private var versionLabel: String {
        if item.versionAbbreviation.isEmpty { return "Identifying version…" }
        if item.versionNamedBySpeaker { return "\(item.versionAbbreviation) (named by speaker)" }
        if item.verseSource == .manual || item.status == .confirmed && item.versionScores.isEmpty { return item.versionAbbreviation }
        if !item.versionSettled && item.confidence == 0 { return "\(item.versionAbbreviation) (default)" }
        return "\(item.versionAbbreviation), \(Int((item.confidence * 100).rounded()))%"
    }

    @ViewBuilder private var versionMenu: some View {
        let scores = Dictionary(item.versionScores.map { ($0.abbreviation, $0.score) }, uniquingKeysWith: max)
        ForEach(model.scripture.translations) { translation in
            Button {
                Task { await model.scripture.changeVersion(of: item, to: translation.abbreviation) }
            } label: {
                if let score = scores[translation.abbreviation] {
                    Text("\(translation.abbreviation) — \(translation.name) (\(Int(score * 100))%)")
                } else {
                    Text("\(translation.abbreviation) — \(translation.name)")
                }
            }
        }
    }

    private var confirmationBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "questionmark.circle").foregroundStyle(.orange)
            Text(item.verseSource == .quote ? "Recognized from the wording." : (item.referenceNote.isEmpty ? "Please confirm." : item.referenceNote))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            ForEach(item.alternatives, id: \.self) { alternative in
                Button(alternative.description) { Task { await model.scripture.changeReference(of: item, to: alternative) } }
                    .controlSize(.small)
            }
            Button("Confirm") { item.status = .confirmed }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            Button("Dismiss") { model.scripture.remove(item) }
                .controlSize(.small)
        }
    }

    @ViewBuilder private var menuItems: some View {
        Menu("Version") { versionMenu }
        if item.status != .confirmed {
            Button("Confirm") { item.status = .confirmed }
        }
        Button("Insert Header Above") { model.insertHeader(.scriptureReading, before: item, in: session) }
        Divider()
        Button("Remove Verse", role: .destructive) { model.scripture.remove(item) }
    }
}

/// ⌘B: add a verse by typing its reference.
struct InsertVerseSheet: View {
    let session: Session
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var abbreviation = ""
    @State private var preview = ""

    private var parsed: DetectedReference? { ReferenceParser.parseManual(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Insert Verse").font(.title2.bold())
            HStack {
                TextField("Reference, e.g. John 3:16 or 1 Cor 13:4-7", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(insert)
                Picker("Version", selection: $abbreviation) {
                    ForEach(model.scripture.translations) { Text($0.abbreviation).tag($0.abbreviation) }
                }
                .labelsHidden()
                .fixedSize()
            }
            Group {
                if let parsed {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(parsed.reference.description).font(.headline)
                        Text(preview.isEmpty ? "Not found in \(abbreviation)." : preview)
                            .font(.system(.body, design: .serif))
                            .foregroundStyle(preview.isEmpty ? .secondary : .primary)
                            .lineLimit(6)
                    }
                } else if !text.isEmpty {
                    Text("Couldn't read that as a Bible reference.").foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 60, alignment: .topLeading)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Insert", action: insert)
                    .keyboardShortcut(.defaultAction)
                    .disabled(parsed == nil)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { abbreviation = model.scripture.defaultAbbreviation }
        .task(id: "\(text)|\(abbreviation)") {
            guard let parsed else { preview = ""; return }
            preview = await model.scripture.text(of: parsed.reference, abbreviation: abbreviation) ?? ""
        }
    }

    private func insert() {
        guard let parsed else { return }
        let time = model.recorder.session === session ? model.recorder.currentTime : session.duration
        Task {
            await model.scripture.insertManual(parsed.reference, abbreviation: abbreviation, in: session, at: time)
            dismiss()
        }
    }
}
