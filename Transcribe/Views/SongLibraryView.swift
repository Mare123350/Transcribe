import SongMatcher
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Browse, edit, import, and export the songs Transcribe listens for.
struct SongLibraryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    @Query(sort: \StoredSong.title) private var songs: [StoredSong]
    @State private var selection: StoredSong?
    @State private var search = ""
    @State private var importing = false
    @State private var exporting = false
    @State private var message: String?

    private var filtered: [StoredSong] {
        guard !search.isEmpty else { return songs }
        return songs.filter { $0.title.localizedCaseInsensitiveContains(search) || $0.artist.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationSplitView {
            List(filtered, selection: $selection) { song in
                VStack(alignment: .leading) {
                    Text(song.title.isEmpty ? "Untitled" : song.title)
                    if !song.artist.isEmpty { Text(song.artist).font(.caption).foregroundStyle(.secondary) }
                }
                .tag(song)
                .contextMenu {
                    Button("Delete", role: .destructive) { delete(song) }
                }
            }
            .searchable(text: $search, placement: .sidebar)
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            .toolbar {
                ToolbarItemGroup {
                    Button { add() } label: { Label("New Song", systemImage: "plus") }
                    Button { importing = true } label: { Label("Import", systemImage: "square.and.arrow.down") }
                        .help("Import songs from JSON or plain text")
                    Button { exporting = true } label: { Label("Export", systemImage: "square.and.arrow.up") }
                        .help("Export the library as JSON")
                }
            }
        } detail: {
            if let selection {
                SongEditor(song: selection)
                    .id(selection.id)
            } else {
                ContentUnavailableView {
                    Label("\(songs.count) Songs", systemImage: "music.note.list")
                } description: {
                    Text("Transcribe recognizes these songs while they're sung and shows the clean lyrics. Modern worship songs are copyrighted: import them under your church's CCLI or similar licence.")
                }
            }
        }
        .navigationTitle("Song Library")
        .onDisappear { model.songs.rebuild() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .plainText], allowsMultipleSelection: true) { result in
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

private struct SongEditor: View {
    @Bindable var song: StoredSong
    @Environment(AppModel.self) private var model
    @State private var sections: [SongSection] = []

    var body: some View {
        Form {
            Section {
                TextField("Title", text: $song.title)
                TextField("Artist / Author", text: $song.artist)
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
                        Button { move(index, by: -1) } label: { Image(systemName: "arrow.up") }.disabled(index == 0)
                        Button { move(index, by: 1) } label: { Image(systemName: "arrow.down") }.disabled(index == sections.count - 1)
                        Button(role: .destructive) { sections.remove(at: index) } label: { Image(systemName: "trash") }
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
