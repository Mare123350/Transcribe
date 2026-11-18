import ScriptureDetector
import SongMatcher
import SwiftUI

/// One field for anything the operator wants on screen: "jn 3 16", "rom 8:28-30 niv", or a song
/// by title, lyric, author or CCLI number. Results appear as you type, verse first, then songs.
/// Return previews, Shift-Return sends, Option-Return adds (verse to the transcript, song to the
/// set list); up and down arrows choose a result.
struct VerseEntryView: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var chosenVersion = ""
    @State private var verseText = ""
    @State private var selection = 0
    /// Song results for the current text, worked out once per pause in typing (not per redraw).
    @State private var songMatches: [(song: StoredSong, result: SongSearchResult)] = []
    @FocusState private var focused: Bool

    private var versions: [String] { model.scripture.allVersionNames.map(\.abbreviation) }
    private var parsed: (reference: DetectedReference, version: String?)? { ReferenceParser.parseEntry(text, versions: versions) }
    /// Only a specific verse or range: "gen 1" alone would put the whole chapter up.
    private var exact: BibleReference? {
        guard let reference = parsed?.reference.reference, reference.verseStart != nil else { return nil }
        return reference
    }
    private var version: String {
        parsed?.version ?? (chosenVersion.isEmpty ? model.scripture.defaultAbbreviation : chosenVersion)
    }
    private var songs: [(song: StoredSong, result: SongSearchResult)] { songMatches }

    /// Results in the order shown: the verse (if any) then songs.
    private enum Result { case verse(BibleReference), song(StoredSong) }
    private var results: [Result] {
        (exact.map { [Result.verse($0)] } ?? []) + songs.map { .song($0.song) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            field
            if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                resultsList
            } else {
                RecentList()
            }
        }
        .task(id: text) {
            let query = text.trimmingCharacters(in: .whitespaces)
            guard query.count >= 2 else { songMatches = []; return }
            // Wait for a pause in typing, so fast typists don't search on every key.
            try? await Task.sleep(for: .milliseconds(90))
            guard !Task.isCancelled else { return }
            songMatches = model.songs.search(query, limit: 6)
        }
        .task(id: "\(text)|\(version)") {
            selection = 0
            guard let exact else { verseText = ""; return }
            verseText = await model.scripture.text(of: exact, abbreviation: version) ?? ""
        }
        .onChange(of: model.verseEntryFocusRequest) { focused = true }
        #if DEBUG
        .onChange(of: model.debugSearchText) { text = model.debugSearchText }
        #endif
    }

    private var field: some View {
        HStack(spacing: Design.Space.s) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Verse or song", text: $text, prompt: Text("Verse or song (jn 3 16)"))
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { act(.preview) }
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) { act(.send); return .handled }
                    if press.modifiers.contains(.option) { act(.add); return .handled }
                    return .ignored
                }
                .onKeyPress(.downArrow) { selection = min(selection + 1, max(results.count - 1, 0)); return .handled }
                .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
                .onExitCommand { text = "" }
                .accessibilityLabel("Find a verse or song")
            Menu(version) {
                ForEach(model.scripture.allVersionNames, id: \.abbreviation) { option in
                    Button("\(option.abbreviation) — \(option.name)") { chosenVersion = option.abbreviation }
                }
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .fixedSize()
            .help("Bible version for verses (or type it after the reference, e.g. “jn 3 16 niv”)")
        }
        .padding(Design.Space.s)
        .background(.background, in: RoundedRectangle(cornerRadius: Design.Radius.small))
        .overlay(RoundedRectangle(cornerRadius: Design.Radius.small).strokeBorder(focused ? Color.accentColor : Color.secondary.opacity(Design.Opacity.border)))
    }

    @ViewBuilder private var resultsList: some View {
        if let parsed, exact == nil, songs.isEmpty {
            Text("Add a verse number, e.g. “\(parsed.reference.reference.description) 1”.")
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
        } else if results.isEmpty {
            Text("No verse or song matches “\(text)”. Try a reference like jn 3 16, or a title or lyric line.")
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: Design.Space.xxs) {
                if let exact {
                    groupLabel("Scripture")
                    row(selected: selection == 0) {
                        VStack(alignment: .leading, spacing: Design.Space.xxs) {
                            Text("\(exact.description) · \(version)").font(.callout.weight(.semibold))
                            Text(verseText.isEmpty ? "Not in \(version)." : verseText)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    } action: { selection = 0; act(.preview) }
                }
                if !songs.isEmpty {
                    groupLabel("Songs")
                    ForEach(Array(songs.enumerated()), id: \.element.song.id) { index, match in
                        let position = index + (exact == nil ? 0 : 1)
                        row(selected: selection == position) {
                            VStack(alignment: .leading, spacing: Design.Space.xxs) {
                                HStack(spacing: Design.Space.xs) {
                                    Image(systemName: "music.note").foregroundStyle(Design.Palette.song)
                                    Text(match.song.title).font(.callout.weight(.semibold)).lineLimit(1)
                                    if match.song.isFavorite { Image(systemName: "star.fill").font(.caption2).foregroundStyle(Design.Palette.favorite) }
                                }
                                Text(subtitle(match))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        } action: { selection = position; act(.preview) }
                        .contextMenu {
                            Button("Show in Preview") { show(.librarySong(match.song.id, section: 0), send: false) }
                            Button("Send to Screen") { show(.librarySong(match.song.id, section: 0), send: true) }
                            Button("Add to Set List") { model.addToSetList(.song(match.song.id), title: match.song.title) }
                        }
                    }
                }
                Text("↩ Preview   ⇧↩ Send   ⌥↩ \(selectedIsVerse ? "Add to transcript" : "Add to set list")")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .padding(.top, Design.Space.xs)
            }
        }
    }

    private var selectedIsVerse: Bool {
        guard results.indices.contains(selection) else { return true }
        if case .verse = results[selection] { return true }
        return false
    }

    private func subtitle(_ match: (song: StoredSong, result: SongSearchResult)) -> String {
        switch match.result.field {
        case .lyrics, .firstLine: "“\(match.result.matchedLine ?? "")”"
        case .number: "CCLI \(match.song.ccliNumber)"
        default: match.song.artist.isEmpty ? (match.song.sections.first?.lyrics.components(separatedBy: .newlines).first ?? "") : match.song.artist
        }
    }

    private func groupLabel(_ title: String) -> some View {
        Text(title).font(Design.Typography.label).foregroundStyle(.secondary).textCase(.uppercase)
            .padding(.top, Design.Space.xs)
    }

    private func row<Content: View>(selected: Bool, @ViewBuilder content: () -> Content, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Design.Space.s)
                .padding(.vertical, Design.Space.xs)
                .background(selected ? Design.Palette.accent.opacity(Design.Opacity.tint) : Color.clear, in: RoundedRectangle(cornerRadius: Design.Radius.small))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private enum Action { case preview, send, add }

    private func act(_ action: Action) {
        guard results.indices.contains(selection) else { return }
        switch results[selection] {
        case .verse(let reference):
            guard !verseText.isEmpty else { return }
            let version = version
            switch action {
            case .preview: show(.passage(reference, version: version), send: false)
            case .send: show(.passage(reference, version: version), send: true)
            case .add: model.insertVerse(reference, version: version)
            }
        case .song(let song):
            switch action {
            case .preview: show(.librarySong(song.id, section: 0), send: false)
            case .send: show(.librarySong(song.id, section: 0), send: true)
            case .add: model.addToSetList(.song(song.id), title: song.title)
            }
        }
        text = ""
    }

    private func show(_ source: OutputSource, send: Bool) {
        Task {
            if send { await model.output.send(source) } else { await model.output.previewOnly(source) }
        }
    }
}

/// Songs and verses shown recently: click to preview again.
private struct RecentList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // Songs since removed from the library are left out.
        let recents = Array(model.output.recents.filter { item in
            if case .song(let id, _) = item { return model.songs.song(id) != nil }
            return true
        }.prefix(8))
        if recents.isEmpty {
            Text("Verses and songs you show appear here for quick reuse.")
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: Design.Space.xxs) {
                Text("Recent").font(Design.Typography.label).foregroundStyle(.secondary).textCase(.uppercase)
                ForEach(recents) { item in
                    Button { Task { await model.output.previewOnly(source(item)) } } label: {
                        HStack(spacing: Design.Space.xs) {
                            Image(systemName: icon(item)).foregroundStyle(color(item)).frame(width: 16)
                            Text(title(item)).lineLimit(1)
                            Spacer()
                            if case .verse(_, let version) = item { Text(version).foregroundStyle(.secondary) }
                        }
                        .font(.callout)
                        .padding(.vertical, Design.Space.xxs)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Show in Preview")
                    .contextMenu {
                        Button("Send to Screen") { Task { await model.output.send(source(item)) } }
                        Button("Show in Preview") { Task { await model.output.previewOnly(source(item)) } }
                        switch item {
                        case .verse(let reference, let version):
                            Button("Add to Transcript") { model.insertVerse(reference, version: version) }
                            Button("Add to Set List") { model.addToSetList(.verse(reference, version: version), title: reference.description) }
                        case .song(let id, let title):
                            Button("Add to Set List") { model.addToSetList(.song(id), title: title) }
                        }
                        Divider()
                        Button("Remove from Recent") { model.output.forget(item) }
                    }
                }
            }
        }
    }

    private func source(_ item: RecentItem) -> OutputSource {
        switch item {
        case .verse(let reference, let version): .passage(reference, version: version)
        case .song(let id, _): .librarySong(id, section: 0)
        }
    }
    private func title(_ item: RecentItem) -> String {
        switch item {
        case .verse(let reference, _): reference.description
        case .song(_, let title): title
        }
    }
    private func icon(_ item: RecentItem) -> String {
        if case .song = item { return "music.note" }
        return "book.closed"
    }
    private func color(_ item: RecentItem) -> Color {
        if case .song = item { return Design.Palette.song }
        return Design.Palette.scripture
    }
}
