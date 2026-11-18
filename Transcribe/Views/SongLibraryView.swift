import SongMatcher
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Browse, edit, import and export the songs Transcribe listens for and can put on screen.
struct SongLibraryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    @Query(sort: \StoredSong.title) private var songs: [StoredSong]
    @State private var selection: StoredSong?
    @State private var search = ""
    @State private var filter = Filter.all
    @State private var importing = false
    @State private var exporting = false
    @State private var message: String?

    enum Filter: Hashable {
        case all, favorites, recent, theme(String)
    }

    private var themes: [String] {
        Array(Set(songs.flatMap(\.themes))).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var filtered: [StoredSong] {
        var list: [StoredSong]
        let query = search.trimmingCharacters(in: .whitespaces)
        if query.isEmpty {
            list = songs
        } else {
            // Ranked search: title, first line, any lyric line, author, CCLI number, typos allowed.
            let ranked = model.songs.searchIndex.search(query, limit: 200).map(\.id)
            let byID = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            list = ranked.compactMap { byID[$0] }
        }
        switch filter {
        case .all: break
        case .favorites: list = list.filter(\.isFavorite)
        case .recent:
            list = list.filter { $0.lastUsed != nil }
            if query.isEmpty { list.sort { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) } }
        case .theme(let theme): list = list.filter { $0.themes.contains { $0.caseInsensitiveCompare(theme) == .orderedSame } }
        }
        return list
    }

    var body: some View {
        NavigationSplitView {
            List(filtered, selection: $selection) { song in
                SongRow(song: song)
                    .tag(song)
                    .contextMenu {
                        Button(song.isFavorite ? "Remove from Favourites" : "Add to Favourites") { song.isFavorite.toggle(); model.songs.rebuild() }
                        Button("Show in Preview") { Task { await model.output.previewOnly(.librarySong(song.id, section: 0)) } }
                        Button("Add to Set List") { model.addToSetList(.song(song.id), title: song.title) }
                        Divider()
                        Button("Delete", role: .destructive) { delete(song) }
                    }
            }
            .searchable(text: $search, placement: .sidebar, prompt: "Title, lyric, author or CCLI #")
            .navigationSplitViewColumnWidth(min: 260, ideal: 300)
            .safeAreaInset(edge: .top) {
                Picker("Show", selection: $filter) {
                    Text("All Songs").tag(Filter.all)
                    Text("Favourites").tag(Filter.favorites)
                    Text("Recently Used").tag(Filter.recent)
                    if !themes.isEmpty {
                        Divider()
                        ForEach(themes, id: \.self) { Text($0).tag(Filter.theme($0)) }
                    }
                }
                .labelsHidden()
                .padding(.horizontal, Design.Space.m)
                .padding(.vertical, Design.Space.xs)
            }
            // Always-visible buttons under the list (toolbar items in a narrow sidebar get hidden).
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: Design.Space.s) {
                    Button { add() } label: { Label("New Song", systemImage: "plus") }
                        .fixedSize()
                        .help("Add a song by typing its lyrics")
                    Button { importing = true } label: { Label("Import…", systemImage: "square.and.arrow.down") }
                        .fixedSize()
                        .help("Import plain text, ChordPro, OpenLyrics, CCLI SongSelect or JSON files")
                    Spacer(minLength: 0)
                    Button { exporting = true } label: { Image(systemName: "square.and.arrow.up") }
                        .help("Export the library as JSON")
                        .disabled(songs.isEmpty)
                }
                .controlSize(.regular)
                .padding(Design.Space.m)
                .background(.bar)
            }
        } detail: {
            if let selection {
                SongEditor(song: selection)
                    .id(selection.id)
            } else if songs.isEmpty {
                ContentUnavailableView {
                    Label("No Songs Yet", systemImage: "music.note.list")
                } description: {
                    Text("Import your library from SongSelect, ChordPro, OpenLyrics or plain text. Modern worship songs are copyrighted: use them under your church's CCLI or similar licence.")
                } actions: {
                    Button { importing = true } label: { Label("Import Songs…", systemImage: "square.and.arrow.down") }
                        .buttonStyle(.borderedProminent)
                    Button { add() } label: { Label("New Song", systemImage: "plus") }
                }
            } else {
                ContentUnavailableView {
                    Label("\(songs.count) Songs", systemImage: "music.note.list")
                } description: {
                    Text("Choose a song to edit it, show it on screen, or add it to this service's set list. Transcribe also recognizes these songs while they're sung.")
                } actions: {
                    Button { add() } label: { Label("New Song", systemImage: "plus") }
                    Button { importing = true } label: { Label("Import Songs…", systemImage: "square.and.arrow.down") }
                }
            }
        }
        .navigationTitle("Song Library")
        .onDisappear { model.songs.rebuild() }
        .fileImporter(isPresented: $importing, allowedContentTypes: Self.importTypes, allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            var total = 0
            var errors: [String] = []
            for url in urls {
                do { total += try model.songs.importSongs(from: url) }
                catch { errors.append("\(url.lastPathComponent): \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)") }
            }
            message = (["Imported \(total) song\(total == 1 ? "" : "s")."] + errors).joined(separator: "\n")
        }
        .fileExporter(isPresented: $exporting, document: SongsDocument(songs: songs.map(\.record)), contentType: .json, defaultFilename: "Transcribe Songs") { _ in }
        .alert("Song Library", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
    }

    static let importTypes: [UTType] = [.json, .plainText, .xml, .text]
        + ["cho", "chordpro", "chopro", "crd", "pro", "usr"].compactMap { UTType(filenameExtension: $0) }

    private func add() {
        let song = StoredSong(record: SongRecord(title: "New Song", sections: [SongSection(name: "Verse 1", lyrics: "")]))
        context.insert(song)
        selection = song
    }

    private func delete(_ song: StoredSong) {
        if selection === song { selection = nil }
        context.delete(song)
        try? context.save()
        model.songs.rebuild()
    }
}

private struct SongRow: View {
    @Bindable var song: StoredSong
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .top, spacing: Design.Space.s) {
            Button {
                song.isFavorite.toggle()
                model.songs.rebuild()
            } label: {
                Image(systemName: song.isFavorite ? "star.fill" : "star")
                    .foregroundStyle(song.isFavorite ? Design.Palette.favorite : Color.secondary.opacity(Design.Opacity.muted))
            }
            .buttonStyle(.plain)
            .help(song.isFavorite ? "Remove from favourites" : "Add to favourites")
            .accessibilityLabel(song.isFavorite ? "Favourite" : "Not a favourite")
            VStack(alignment: .leading, spacing: Design.Space.xxs) {
                Text(song.title.isEmpty ? "Untitled" : song.title).lineLimit(1)
                let detail = [song.artist, song.ccliNumber.isEmpty ? "" : "CCLI \(song.ccliNumber)"].filter { !$0.isEmpty }.joined(separator: " · ")
                if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                if !song.themes.isEmpty {
                    Text(song.themes.joined(separator: " · ")).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, Design.Space.xxs)
    }
}

private struct SongEditor: View {
    @Bindable var song: StoredSong
    @Environment(AppModel.self) private var model
    @State private var sections: [SongSection] = []

    var body: some View {
        Form {
            Section {
                HStack(spacing: Design.Space.s) {
                    Button { Task { await model.output.previewOnly(.librarySong(song.id, section: 0)) } } label: {
                        Label("Show in Preview", systemImage: "eye")
                    }
                    Button { Task { await model.output.send(.librarySong(song.id, section: 0)) } } label: {
                        Label("Send to Screen", systemImage: "rectangle.on.rectangle.angled")
                    }
                    .buttonStyle(.borderedProminent)
                    Button { model.addToSetList(.song(song.id), title: song.title) } label: {
                        Label("Add to Set List", systemImage: "text.badge.plus")
                    }
                    Spacer()
                    Toggle(isOn: $song.isFavorite) { Label("Favourite", systemImage: "star") }
                        .toggleStyle(.button)
                }
            }
            Section("Details") {
                TextField("Title", text: $song.title)
                TextField("Author", text: $song.artist)
                TextField("CCLI song number", text: $song.ccliNumber)
                TextField("Copyright", text: $song.copyright)
                TextField("Themes", text: $song.themesRaw, prompt: Text("Grace, Easter, Communion"))
            }
            ForEach(sections.indices, id: \.self) { index in
                Section {
                    TextField("Section name", text: $sections[index].name)
                    TextEditor(text: $sections[index].lyrics)
                        .font(.body)
                        .frame(minHeight: 90)
                } header: {
                    HStack {
                        Text(sections[index].name.isEmpty ? "Section \(index + 1)" : sections[index].name)
                        Spacer()
                        Button { Task { await model.output.previewOnly(.librarySong(song.id, section: index)) } } label: { Image(systemName: "eye") }
                            .help("Show this section in Preview")
                        Button { move(index, by: -1) } label: { Image(systemName: "arrow.up") }.disabled(index == 0)
                            .help("Move up")
                        Button { move(index, by: 1) } label: { Image(systemName: "arrow.down") }.disabled(index == sections.count - 1)
                            .help("Move down")
                        Button(role: .destructive) { sections.remove(at: index) } label: { Image(systemName: "trash") }
                            .help("Delete section")
                    }
                    .buttonStyle(.borderless)
                }
            }
            Section {
                Menu("Add Section") {
                    ForEach(["Verse \(sections.filter { $0.name.hasPrefix("Verse") }.count + 1)", "Chorus", "Pre-Chorus", "Bridge", "Tag"], id: \.self) { name in
                        Button(name) { sections.append(SongSection(name: name, lyrics: "")) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { sections = song.sections }
        .onChange(of: sections) { song.sections = sections }
        .onDisappear {
            try? song.modelContext?.save()
            model.songs.rebuild()
        }
    }

    private func move(_ index: Int, by offset: Int) {
        let target = index + offset
        guard sections.indices.contains(target) else { return }
        sections.swapAt(index, target)
    }
}

struct SongsDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var songs: [SongRecord]

    init(songs: [SongRecord]) { self.songs = songs }

    init(configuration: ReadConfiguration) throws {
        songs = try SongImporter.songs(fromJSON: configuration.file.regularFileContents ?? Data())
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try SongImporter.json(for: songs))
    }
}
