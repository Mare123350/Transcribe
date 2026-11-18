import SwiftData
import SwiftUI

/// The live, scrolling transcript of one session.
struct TranscriptView: View {
    @Bindable var session: Session
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.fontSize) private var fontSize = 16.0
    @State private var followLive = true
    @State private var atBottom = true
    @State private var userScrolling = false

    private static let bottomID = "transcript-bottom"

    var body: some View {
        // The batched layout: reading `session.layout` here would redraw for every phrase.
        let layout = session.feed.layout
        let isLive = model.recorder.session === session && model.recorder.isActive
        // In "Scripture and songs only" the listening line sits in a bar under the list rather than
        // in it: its text changes several times a second, and inside the lazy stack every change
        // made the stack measure its rows again.
        let listeningBar = isLive && model.recorder.mode == .detections
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Design.Space.m) {
                    TranscriptHeaderView(session: session, isLive: isLive, hasPhrases: layout.rows.count > layout.headers.count + layout.songs.count + layout.verses.count)
                        .padding(.bottom, Design.Space.s)

                    ForEach(layout.rows) { row in
                        TranscriptItemRow(item: row.item, session: session, children: layout.children[row.id] ?? [])
                            .id(row.id)
                    }

                    if isLive && !listeningBar {
                        // Reads the in-progress text itself, so only this row redraws as words arrive.
                        VolatileRow()
                    }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .font(.system(size: fontSize))
                .padding(.horizontal, Design.Layout.pageGutter)
                .padding(.vertical, Design.Space.xl)
                .frame(maxWidth: Design.Layout.readingWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            // Scrolling up yourself pauses following the live text; scrolling back down resumes it.
            // Content growing at the bottom doesn't count: only scrolls the user is making.
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 80
            } action: { _, bottom in
                atBottom = bottom
                if userScrolling { followLive = bottom }
            }
            .onScrollPhaseChange { _, phase in
                userScrolling = phase == .interacting || phase == .tracking || phase == .decelerating
                if userScrolling && !atBottom { followLive = false }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if listeningBar {
                    VolatileRow()
                        .padding(.horizontal, Design.Layout.pageGutter)
                        .padding(.vertical, Design.Space.s)
                        .frame(maxWidth: Design.Layout.readingWidth, alignment: .leading)
                        .frame(maxWidth: .infinity)
                        .background(Color(nsColor: .textBackgroundColor))
                }
            }
            // Following live. Not animated: an animated scroll in a lazy list measures the rows on
            // every frame of the animation, which got slower with every card in a long service.
            .onChange(of: layout.ordered.count) {
                if isLive && followLive { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
            .background {
                if isLive && followLive && !listeningBar { FollowVolatileText(proxy: proxy, target: Self.bottomID) }
            }
            .onChange(of: model.scrollTarget) {
                guard let target = model.scrollTarget else { return }
                followLive = false
                withAnimation(Design.Motion.scroll) { proxy.scrollTo(target, anchor: .top) }
                model.scrollTarget = nil
            }
            .overlay(alignment: .top) {
                if let id = model.songs.pendingItemID, let pending = layout.songs.last(where: { $0.id == id }), pending.status == .detected {
                    DetectedSongChip(item: pending)
                        .padding(.top, Design.Space.s)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(Design.Motion.enter, value: model.songs.pendingItemID)
            .overlay(alignment: .bottomTrailing) {
                if isLive && !followLive {
                    Button {
                        followLive = true
                        withAnimation(Design.Motion.scroll) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                    } label: {
                        Label("Jump to Live", systemImage: "arrow.down.to.line")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.end, modifiers: [.command])
                    .help("Scroll to the newest text and keep following it (⌘↘)")
                    .padding()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .modifier(SessionWindowTitle(session: session))
    }
}

/// The window title and subtitle. Reads the duration and save time on its own, so their updates
/// while recording don't rebuild the transcript.
private struct SessionWindowTitle: ViewModifier {
    let session: Session
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
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
    let isLive: Bool
    /// The service has transcribed phrases (not only cards and headers).
    let hasPhrases: Bool
    @Environment(AppModel.self) private var model
    @State private var hasAudio = false

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.xs) {
            TextField("Session title", text: $session.title)
                .textFieldStyle(.plain)
                .font(.largeTitle.bold())
            Text(session.createdAt.formatted(date: .complete, time: .shortened))
                .foregroundStyle(.secondary)
            if !isLive && !hasPhrases && hasAudio {
                generateRow
                    .padding(.top, Design.Space.s)
            }
        }
        .task(id: "\(session.id)-\(isLive)") { hasAudio = ServiceAudio.hasAudio(for: session.id) }
    }

    /// Recorded with "Scripture and songs only": the words can be transcribed from the saved audio.
    @ViewBuilder private var generateRow: some View {
        let generator = model.transcriptGenerator
        HStack(spacing: Design.Space.s) {
            if let progress = generator.progress[session.id] {
                ProgressView(value: progress)
                    .frame(maxWidth: 220)
                Text("Transcribing… \(Int(progress * 100))%")
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                Button("Cancel") { generator.cancel(session) }
                    .controlSize(.small)
            } else {
                Button {
                    generator.generate(session, context: model.context)
                } label: {
                    Label("Generate Full Transcript", systemImage: "text.quote")
                }
                .help("Transcribe this service's saved audio and add every word between the cards")
                if let error = generator.errors[session.id] {
                    Text(error).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Keeps the newest words in view as they arrive (Full transcript). Separate so the transcript
/// itself doesn't re-render for every partial result.
private struct FollowVolatileText: View {
    let proxy: ScrollViewProxy
    let target: String
    @Environment(AppModel.self) private var model

    var body: some View {
        // Only when the live text may have wrapped onto another line.
        Color.clear
            .onChange(of: model.recorder.volatileText.count / 60) { proxy.scrollTo(target, anchor: .bottom) }
    }
}

/// Text the speech model is still working on, shown in grey until it's finalized. In "Scripture
/// and songs only" it's one quiet line of the last few words heard, replacing itself.
private struct VolatileRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.recorder.mode == .detections { listeningLine } else { volatileText }
    }

    // The symbols stay still: an animated symbol makes SwiftUI redraw and re-lay-out the window on
    // the main thread every frame for the whole service. The toolbar meter shows it's listening.
    private var listeningLine: some View {
        let words = model.recorder.heardLine
        let paused = model.recorder.state == .paused
        return HStack(alignment: .firstTextBaseline, spacing: Design.Space.m) {
            Image(systemName: paused ? "pause.circle" : "waveform")
                .foregroundStyle(.secondary)
                .frame(width: TimestampLabel.width, alignment: .trailing)
            Text("\(Text(paused ? "Paused" : "Listening…").italic())\(words.isEmpty ? "" : "   " + words)")
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(paused ? "Paused" : "Listening")
    }

    private var volatileText: some View {
        let text = model.recorder.volatileText
        let paused = model.recorder.state == .paused
        return HStack(alignment: .firstTextBaseline, spacing: Design.Space.m) {
            Image(systemName: paused ? "pause.circle" : "waveform")
                .foregroundStyle(.secondary)
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
            .font(Design.Typography.timestamp)
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
        HStack(alignment: .firstTextBaseline, spacing: Design.Space.m) {
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
