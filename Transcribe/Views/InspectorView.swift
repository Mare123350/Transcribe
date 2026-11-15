import SwiftUI

/// Quick navigation: every header, song, and verse in the session. Click to jump there.
struct InspectorView: View {
    let session: Session
    @Environment(AppModel.self) private var model

    var body: some View {
        let layout = session.layout
        let headers = layout.headers, songs = layout.songs, verses = layout.verses

        List {
            Section("Screen") {
                VerseEntryView()
                OutputPanel()
            }
            Section {
                SetListSection(session: session)
            } header: {
                HStack {
                    Text("Set List")
                    Spacer()
                    if !session.setList.isEmpty {
                        Button("Next ↓") { model.stepSetList(by: 1) }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                            .fixedSize()
                            .padding(.trailing, Design.Space.xs)
                            .help("Put the next item in Preview (⌥⌘↓)")
                    }
                }
            }
            Section("Sections") {
                if headers.isEmpty { emptyRow("Headers appear as the service moves on.") }
                ForEach(headers) { item in
                    jumpRow(item) {
                        Label {
                            VStack(alignment: .leading) {
                                Text(item.title.isEmpty ? "Untitled section" : item.title)
                                if !item.subtitle.isEmpty {
                                    Text(item.subtitle).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        } icon: {
                            Image(systemName: item.sectionType?.symbol ?? "number")
                        }
                    }
                }
            }
            Section("Songs") {
                if songs.isEmpty { emptyRow("Songs from the library are detected while they're sung.") }
                ForEach(songs) { item in
                    jumpRow(item) {
                        Label {
                            VStack(alignment: .leading) {
                                Text(item.title)
                                Text(item.status == .confirmed ? "Confirmed" : "Detected · \(Int(item.confidence * 100))%")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "music.note")
                        }
                    }
                }
            }
            Section("Scripture") {
                if verses.isEmpty { emptyRow("Bible references and quoted verses appear here.") }
                ForEach(verses) { item in
                    jumpRow(item) {
                        Label {
                            VStack(alignment: .leading) {
                                Text(item.reference)
                                Text(versionLine(item)).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "book.closed")
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        // Hints and labels here wrap instead of being cut off.
        .lineLimit(nil)
    }

    private func jumpRow<Content: View>(_ item: TranscriptItem, @ViewBuilder content: () -> Content) -> some View {
        Button { model.scrollTarget = item.id } label: {
            HStack(alignment: .firstTextBaseline) {
                content()
                Spacer()
                Text(TimeFormat.clock(item.timestamp)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    private func versionLine(_ item: TranscriptItem) -> String {
        guard !item.versionAbbreviation.isEmpty else { return "Identifying version…" }
        if item.versionNamedBySpeaker { return "\(item.versionAbbreviation) · named by speaker" }
        if item.verseSource == .manual { return item.versionAbbreviation }
        return "\(item.versionAbbreviation) · \(Int(item.confidence * 100))%"
    }
}

/// Songs and verses planned for this service. Click to preview, drag to reorder.
private struct SetListSection: View {
    let session: Session
    @Environment(AppModel.self) private var model

    var body: some View {
        let list = session.setList
        if list.isEmpty {
            Text("Plan this service: find a song or verse above, then press ⌥↩ or right-click it and choose Add to Set List.")
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            let current = model.currentSetListIndex
            ForEach(Array(list.enumerated()), id: \.element.id) { index, item in
                Button { Task { await model.output.previewOnly(model.source(for: item)) } } label: {
                    HStack(spacing: Design.Space.s) {
                        Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 16, alignment: .trailing)
                        Image(systemName: isSong(item) ? "music.note" : "book.closed")
                            .foregroundStyle(isSong(item) ? Design.Palette.song : Design.Palette.scripture)
                        Text(item.title).lineLimit(1)
                        Spacer()
                        if index == current {
                            Text(model.output.live.map { model.source(for: item).matches($0.source) } == true ? "LIVE" : "PREVIEW")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(model.output.live.map { model.source(for: item).matches($0.source) } == true ? Design.Palette.live : Color.accentColor)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show in Preview")
                .contextMenu {
                    Button("Show in Preview") { Task { await model.output.previewOnly(model.source(for: item)) } }
                    Button("Send to Screen") { Task { await model.output.send(model.source(for: item)) } }
                    Divider()
                    Button("Remove from Set List", role: .destructive) { model.removeFromSetList(item) }
                }
            }
            .onMove { model.moveSetList(from: $0, to: $1) }
        }
    }

    private func isSong(_ item: SetListItem) -> Bool {
        if case .song = item.kind { return true }
        return false
    }
}
