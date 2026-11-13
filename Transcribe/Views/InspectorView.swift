import SwiftUI

/// Quick navigation: every header, song, and verse in the session. Click to jump there.
struct InspectorView: View {
    let session: Session
    @Environment(AppModel.self) private var model

    var body: some View {
        let layout = session.layout
        let headers = layout.headers, songs = layout.songs, verses = layout.verses

        List {
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
