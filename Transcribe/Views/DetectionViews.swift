import SongMatcher
import SwiftData
import SwiftUI

/// A song from the library, shown with its clean lyrics in place of the sung transcription.
struct SongBlockView: View {
    @Bindable var item: TranscriptItem
    let session: Session
    let sungSegments: [TranscriptItem]
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.fontSize) private var fontSize = 16.0
    @State private var showSung = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            TimestampLabel(seconds: item.timestamp)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "music.note").foregroundStyle(.purple)
                    Text("Song: \(item.title)").font(.headline)
                    if !item.artist.isEmpty {
                        Text(item.artist).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if item.status == .detected {
                        Text("\(Int(item.confidence * 100))% match")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                ForEach(Array(item.lyricSections.enumerated()), id: \.offset) { _, section in
                    VStack(alignment: .leading, spacing: 2) {
                        if !section.name.isEmpty {
                            Text(section.name)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.purple)
                                .textCase(.uppercase)
                        }
                        Text(section.lyrics)
                            .font(.system(size: fontSize))
                            .textSelection(.enabled)
                    }
                }
                if item.lyricSections.isEmpty {
                    Text("Listening for the lyrics…").foregroundStyle(.secondary).italic()
                }

                if !sungSegments.isEmpty {
                    DisclosureGroup(isExpanded: $showSung) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(sungSegments) { segment in
                                Text(segment.text).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Text("Sung transcription (\(sungSegments.count) \(sungSegments.count == 1 ? "line" : "lines"))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.purple.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .leading) {
                UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10).fill(.purple).frame(width: 4)
            }
        }
        .contextMenu {
            if item.status == .detected { Button("Confirm Song") { model.songs.confirm(item) } }
            SongPickerMenu(title: "Change Song") { model.songs.change(item, to: $0) }
            Button("Insert Header Above") { model.insertHeader(.worship, before: item, in: session) }
            Divider()
            Button("Not a Song — Restore Transcript", role: .destructive) { model.songs.dismiss(item) }
        }
    }
}

/// "Detected: Amazing Grace (87%)" — confirm, change, or dismiss the latest detection.
struct DetectedSongChip: View {
    let item: TranscriptItem
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "music.note")
                .foregroundStyle(.purple)
            Text("Detected: **\(item.title)** (\(Int(item.confidence * 100))%)")
                .lineLimit(1)
            Button("Confirm") { model.songs.confirm(item) }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
            SongPickerMenu(title: "Change") { model.songs.change(item, to: $0) }
                .fixedSize()
            Button { model.songs.dismiss(item) } label: { Image(systemName: "xmark") }
                .help("Not a song: restore the transcript")
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }
}

/// A menu listing every song in the library.
struct SongPickerMenu: View {
    let title: String
    let action: (StoredSong) -> Void
    @Query(sort: \StoredSong.title) private var songs: [StoredSong]

    var body: some View {
        Menu(title) {
            ForEach(songs) { song in
                Button(song.artist.isEmpty ? song.title : "\(song.title) — \(song.artist)") { action(song) }
            }
        }
    }
}
