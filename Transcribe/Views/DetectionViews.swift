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
        HStack(alignment: .top, spacing: Design.Space.m) {
            TimestampLabel(seconds: item.timestamp)
            VStack(alignment: .leading, spacing: Design.Space.m) {
                HStack(alignment: .firstTextBaseline, spacing: Design.Space.s) {
                    Image(systemName: "music.note").foregroundStyle(Design.Palette.song)
                    Text("Song: \(item.title)").font(.headline)
                    if !item.artist.isEmpty {
                        Text(item.artist).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if item.status == .detected {
                        Text("\(Int(item.confidence * 100))% match")
                            .font(Design.Typography.timestamp)
                            .foregroundStyle(.secondary)
                    }
                    if let last = item.lyricSections.last {
                        SendToScreenButtons(source: .song(item.id, section: model.output.songSectionIndex(item.id, matching: last)))
                    }
                }

                ForEach(Array(item.lyricSections.enumerated()), id: \.offset) { _, section in
                    VStack(alignment: .leading, spacing: Design.Space.xxs) {
                        if !section.name.isEmpty {
                            Text(section.name)
                                .font(Design.Typography.label)
                                .foregroundStyle(Design.Palette.song)
                                .textCase(.uppercase)
                        }
                        Text(section.lyrics)
                            .font(.system(size: fontSize))
                            .textSelection(.enabled)
                    }
                    .contextMenu {
                        let index = model.output.songSectionIndex(item.id, matching: section)
                        Button("Send “\(section.name.isEmpty ? "Section" : section.name)” to Screen") { Task { await model.output.send(.song(item.id, section: index)) } }
                        Button("Show in Preview") { Task { await model.output.showInPreview(.song(item.id, section: index)) } }
                    }
                }
                if item.lyricSections.isEmpty {
                    Text("Listening for the lyrics…").foregroundStyle(.secondary).italic()
                }

                if !sungSegments.isEmpty {
                    DisclosureGroup(isExpanded: $showSung) {
                        VStack(alignment: .leading, spacing: Design.Space.xs) {
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
            .padding(Design.Layout.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Design.Palette.song.opacity(Design.Opacity.wash), in: RoundedRectangle(cornerRadius: Design.Radius.medium))
            .overlay(alignment: .leading) {
                UnevenRoundedRectangle(topLeadingRadius: Design.Radius.medium, bottomLeadingRadius: Design.Radius.medium).fill(Design.Palette.song).frame(width: Design.Layout.cardStripe)
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
        HStack(spacing: Design.Space.s) {
            Image(systemName: "music.note")
                .foregroundStyle(Design.Palette.song)
            Text("Detected: **\(item.title)** (\(Int(item.confidence * 100))%)")
                .lineLimit(1)
            Button("Confirm") { model.songs.confirm(item) }
                .buttonStyle(.borderedProminent)
                .tint(Design.Palette.song)
            SongPickerMenu(title: "Change") { model.songs.change(item, to: $0) }
                .fixedSize()
            Button { model.songs.dismiss(item) } label: { Image(systemName: "xmark") }
                .help("Not a song: restore the transcript")
        }
        .controlSize(.small)
        .padding(.horizontal, Design.Space.m)
        .padding(.vertical, Design.Space.s)
        .background(.regularMaterial, in: Capsule())
        .floatingShadow()
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
