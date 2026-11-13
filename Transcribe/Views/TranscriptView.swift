import SwiftData
import SwiftUI

/// The live, scrolling transcript of one session.
struct TranscriptView: View {
    @Bindable var session: Session
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.fontSize) private var fontSize = 16.0
    @State private var followLive = true

    private static let bottomID = "transcript-bottom"

    var body: some View {
        let layout = session.layout
        let isLive = model.recorder.session === session && model.recorder.isActive
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    TranscriptHeaderView(session: session)
                        .padding(.bottom, 8)

                    ForEach(layout.rows) { row in
                        TranscriptItemRow(item: row.item, session: session, children: layout.children[row.id] ?? [])
                            .id(row.id)
                    }

                    if isLive {
                        // Reads the in-progress text itself, so only this row redraws as words arrive.
                        VolatileRow()
                    }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .font(.system(size: fontSize))
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: layout.ordered.count) {
                if isLive && followLive { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.bottomID, anchor: .bottom) } }
            }
            .background {
                if isLive && followLive { FollowVolatileText(proxy: proxy, target: Self.bottomID) }
            }
            .onChange(of: model.scrollTarget) {
                guard let target = model.scrollTarget else { return }
                followLive = false
                withAnimation { proxy.scrollTo(target, anchor: .top) }
                model.scrollTarget = nil
            }
            .overlay(alignment: .top) {
                if let id = model.songs.pendingItemID, let pending = layout.songs.last(where: { $0.id == id }), pending.status == .detected {
                    DetectedSongChip(item: pending)
                        .padding(.top, 10)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: model.songs.pendingItemID)
            .overlay(alignment: .bottomTrailing) {
                if isLive && !followLive {
                    Button {
                        followLive = true
                        withAnimation { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                    } label: {
                        Label("Follow Live", systemImage: "arrow.down.to.line")
                    }
                    .buttonStyle(.borderedProminent)
                    .padding()
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .navigationTitle(session.title.isEmpty ? "Untitled" : session.title)
        .navigationSubtitle(subtitle)
    }

    private var subtitle: String {
        var parts = [TimeFormat.clock(session.duration)]
        if let saved = model.recorder.lastAutosave, model.recorder.session === session, model.recorder.isActive {
            parts.append("Saved \(saved.formatted(date: .omitted, time: .standard))")
        }
        return parts.joined(separator: " · ")
    }
}

private struct TranscriptHeaderView: View {
    @Bindable var session: Session

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Session title", text: $session.title)
                .textFieldStyle(.plain)
                .font(.largeTitle.bold())
            Text(session.createdAt.formatted(date: .complete, time: .shortened))
                .foregroundStyle(.secondary)
        }
    }
}

/// Keeps the newest words in view as they arrive. Separate so the transcript itself doesn't
/// re-render for every partial result.
private struct FollowVolatileText: View {
    let proxy: ScrollViewProxy
    let target: String
    @Environment(AppModel.self) private var model

    var body: some View {
        Color.clear
            .onChange(of: model.recorder.volatileText) { proxy.scrollTo(target, anchor: .bottom) }
    }
}

/// Text the speech model is still working on, shown in grey until it's finalized.
private struct VolatileRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let text = model.recorder.volatileText
        let paused = model.recorder.state == .paused
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: paused ? "pause.circle" : "waveform")
                .foregroundStyle(.secondary)
                .symbolEffect(.variableColor.iterative, isActive: !paused)
                .frame(width: TimestampLabel.width, alignment: .trailing)
            Text(text.isEmpty ? (paused ? "Paused" : "Listening…") : text)
                .foregroundStyle(.secondary)
                .italic(text.isEmpty)
        }
    }
}

struct TimestampLabel: View {
    static let width: CGFloat = 56
    let seconds: TimeInterval

    var body: some View {
        Text(TimeFormat.clock(seconds))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.tertiary)
            .frame(width: Self.width, alignment: .trailing)
    }
}

/// Picks the right view for each kind of transcript item.
struct TranscriptItemRow: View {
    let item: TranscriptItem
    let session: Session
    let children: [TranscriptItem]

    var body: some View {
        switch item.kind {
        case .segment: SegmentRow(item: item, session: session)
        case .header: HeaderRow(item: item, session: session)
        case .song: SongBlockView(item: item, session: session, sungSegments: children)
        case .verse: VerseCalloutView(item: item, session: session)
        }
    }
}

struct SegmentRow: View {
    @Bindable var item: TranscriptItem
    let session: Session
    @Environment(AppModel.self) private var model
    @State private var editing = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            TimestampLabel(seconds: item.timestamp)
            if editing {
                TextField("Text", text: $item.text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .onSubmit { editing = false }
            } else {
                Text(item.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .contextMenu {
            Button(editing ? "Done Editing" : "Edit Text") { editing.toggle() }
            if !item.originalText.isEmpty {
                Button("Restore Original Wording") {
                    item.text = item.originalText
                    item.originalText = ""
                }
            }
            Button("Insert Header Above") { model.insertHeader(before: item, in: session) }
            Divider()
            Button("Delete", role: .destructive) { model.context.delete(item) }
        }
    }
}
