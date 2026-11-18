import Foundation
import ScriptureDetector
import SwiftData

/// One recorded service.
@Model
final class Session {
    var id: UUID = UUID()
    var title: String = ""
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    /// Seconds of recorded audio.
    var duration: TimeInterval = 0
    var localeIdentifier: String = ""
    var engineName: String = ""
    /// True while recording. Still true at launch means the app quit unexpectedly mid-service.
    var isRecording: Bool = false
    /// Songs and verses planned for this service, in order (JSON of [SetListItem]).
    var setListData: Data?

    @Relationship(deleteRule: .cascade, inverse: \TranscriptItem.session)
    var items: [TranscriptItem] = []

    var setList: [SetListItem] {
        get { setListData.flatMap { try? JSONDecoder().decode([SetListItem].self, from: $0) } ?? [] }
        set { setListData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue) }
    }

    init(title: String, localeIdentifier: String) {
        self.title = title
        self.localeIdentifier = localeIdentifier
    }

    /// Items in transcript order. Cached: sorting thousands of SwiftData objects on every view
    /// update was the main cost of a long transcript.
    @MainActor var orderedItems: [TranscriptItem] { layout.ordered }

    /// The transcript in order, split into top-level rows and the items folded under each song or
    /// verse (sung lines, a passage read aloud).
    @MainActor var layout: TranscriptLayout { TranscriptLayout.for(self) }

    @MainActor var nextSortIndex: Double {
        (layout.ordered.last?.sortIndex ?? 0) + 1
    }

    /// A sort index that places a new item directly before `item`.
    @MainActor func sortIndex(before item: TranscriptItem) -> Double {
        let ordered = layout.ordered
        guard let index = ordered.firstIndex(where: { $0 === item }) else { return sortIndex(at: item.timestamp, after: false) }
        let previous = index > 0 ? ordered[index - 1].sortIndex : item.sortIndex - 1
        return (previous + item.sortIndex) / 2
    }

    /// A sort index that places a new item directly after `item`.
    @MainActor func sortIndex(after item: TranscriptItem) -> Double {
        let ordered = layout.ordered
        guard let index = ordered.lastIndex(where: { $0 === item }) else { return sortIndex(at: item.timestamp, after: true) }
        let next = index + 1 < ordered.count ? ordered[index + 1].sortIndex : item.sortIndex + 1
        return (item.sortIndex + next) / 2
    }

    /// For a phrase that isn't in the service ("Scripture and songs only"): a sort index that
    /// places the new item by time among the cards and headers that are, before items at the
    /// same time or (`after`) after them.
    @MainActor private func sortIndex(at time: TimeInterval, after: Bool) -> Double {
        let top = layout.rows.map(\.item)
        // Usually at or near the end: search from there.
        var index = top.count
        while index > 0, after ? top[index - 1].timestamp > time : top[index - 1].timestamp >= time { index -= 1 }
        let previous = index > 0 ? top[index - 1].sortIndex : (top.first?.sortIndex ?? 1) - 1
        // Between this row and the next one in the full order (which may be a folded child).
        let ordered = layout.ordered
        let next: Double
        if index > 0, let position = ordered.lastIndex(where: { $0 === top[index - 1] }) {
            var after = position + 1
            while after < ordered.count, ordered[after].parentItemID == top[index - 1].id { after += 1 }
            let lastChild = ordered[position..<after].last?.sortIndex ?? previous
            let following = after < ordered.count ? ordered[after].sortIndex : lastChild + 1
            return (lastChild + following) / 2
        } else {
            next = top.first?.sortIndex ?? previous + 2
        }
        return (previous + next) / 2
    }

    static func defaultTitle(for date: Date = .now) -> String {
        "Service — " + date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().hour().minute())
    }
}

/// A session's items in order, rebuilt only when items are added or removed, or when
/// `invalidate` is called (an item folded under a song or verse, or moved).
///
/// Checking the cache costs nothing per item: reading a property of thousands of SwiftData objects
/// on every view update was what made long transcripts slow.
@MainActor
struct TranscriptLayout {
    struct Row: Identifiable {
        let id: UUID
        let item: TranscriptItem
    }

    let ordered: [TranscriptItem]
    /// Top-level rows with their ids read once, so lists don't touch SwiftData to diff.
    let rows: [Row]
    let children: [UUID: [TranscriptItem]]
    let headers: [TranscriptItem]
    let songs: [TranscriptItem]
    let verses: [TranscriptItem]

    var topLevel: [TranscriptItem] { rows.map(\.item) }

    /// What the layout needs from an item, read from SwiftData once (each read costs microseconds,
    /// which adds up to tens of milliseconds over a 2-hour transcript).
    private struct Snapshot {
        let item: TranscriptItem
        let object: ObjectIdentifier
        let sortIndex: Double
        let id: UUID
        var parent: UUID?
        let kind: String

        @MainActor init(_ item: TranscriptItem) {
            self.item = item
            object = ObjectIdentifier(item)
            sortIndex = item.sortIndex
            id = item.id
            parent = item.parentItemID
            kind = item.kindRaw
        }
    }

    private struct Entry {
        var snapshots: [Snapshot]
        var objects: Set<ObjectIdentifier>
        var revision: Int
        var layout: TranscriptLayout
    }

    private static var cache: [ObjectIdentifier: Entry] = [:]

    /// Call after changing an item's `parentItemID` or `sortIndex`.
    static func invalidate(_ session: Session?) {
        guard let session else { return }
        LayoutRevisions.shared.bump(session)
    }

    static func `for`(_ session: Session) -> TranscriptLayout {
        let items = session.items
        let key = ObjectIdentifier(session)
        let revision = LayoutRevisions.shared.revision(of: session)

        guard var entry = cache[key] else {
            // First look at this session: load its items in one sorted query rather than one by one.
            let sessionID = session.id
            let fetched = (try? session.modelContext?.fetch(FetchDescriptor<TranscriptItem>(
                predicate: #Predicate { $0.session?.id == sessionID }, sortBy: [SortDescriptor(\.sortIndex)]
            ))) ?? []
            let source = fetched.count == items.count ? fetched : items
            let snapshots = source.map(Snapshot.init).sorted { $0.sortIndex < $1.sortIndex }
            let entry = Entry(snapshots: snapshots, objects: Set(snapshots.map(\.object)), revision: revision, layout: build(snapshots))
            cache[key] = entry
            return entry.layout
        }
        if entry.snapshots.count == items.count && entry.revision == revision { return entry.layout }

        // Items added or removed: update the cached order instead of sorting again.
        let current = Set(items.map { ObjectIdentifier($0) })
        if current != entry.objects {
            entry.snapshots.removeAll { !current.contains($0.object) }
            for item in items where !entry.objects.contains(ObjectIdentifier(item)) {
                let snapshot = Snapshot(item)
                var low = 0, high = entry.snapshots.count
                while low < high {
                    let mid = (low + high) / 2
                    if entry.snapshots[mid].sortIndex <= snapshot.sortIndex { low = mid + 1 } else { high = mid }
                }
                entry.snapshots.insert(snapshot, at: low)
            }
            entry.objects = current
        }
        // Something was folded or moved: re-read what can change.
        if entry.revision != revision {
            let resorted = entry.snapshots.contains { $0.item.sortIndex != $0.sortIndex }
            if resorted {
                entry.snapshots = items.map(Snapshot.init).sorted { $0.sortIndex < $1.sortIndex }
            } else {
                for index in entry.snapshots.indices { entry.snapshots[index].parent = entry.snapshots[index].item.parentItemID }
            }
            entry.revision = revision
        }
        entry.layout = build(entry.snapshots)
        cache[key] = entry
        return entry.layout
    }

    private static func build(_ snapshots: [Snapshot]) -> TranscriptLayout {
        var rows: [Row] = []
        var children: [UUID: [TranscriptItem]] = [:]
        var headers: [TranscriptItem] = [], songs: [TranscriptItem] = [], verses: [TranscriptItem] = []
        rows.reserveCapacity(snapshots.count)
        for snapshot in snapshots {
            if let parent = snapshot.parent {
                children[parent, default: []].append(snapshot.item)
                continue
            }
            rows.append(Row(id: snapshot.id, item: snapshot.item))
            switch snapshot.kind {
            case ItemKind.header.rawValue: headers.append(snapshot.item)
            case ItemKind.song.rawValue: songs.append(snapshot.item)
            case ItemKind.verse.rawValue: verses.append(snapshot.item)
            default: break
            }
        }
        return TranscriptLayout(ordered: snapshots.map(\.item), rows: rows, children: children, headers: headers, songs: songs, verses: verses)
    }
}

/// Bumped when a transcript's layout changes without items being added or removed. Observable,
/// so views showing the transcript update.
@MainActor
@Observable
final class LayoutRevisions {
    static let shared = LayoutRevisions()
    private var values: [ObjectIdentifier: Int] = [:]

    func revision(of session: Session) -> Int { values[ObjectIdentifier(session)] ?? 0 }
    func bump(_ session: Session) { values[ObjectIdentifier(session), default: 0] += 1 }
}

/// One planned item in a service's set list.
struct SetListItem: Codable, Hashable, Identifiable {
    enum Kind: Codable, Hashable {
        case song(UUID)
        case verse(BibleReference, version: String)
    }
    var id = UUID()
    var kind: Kind
    /// Shown in the list: the song title or the reference.
    var title: String
}

/// What views show of a transcript: its layout, refreshed at most about three times a second.
///
/// Views read `layout` here instead of `session.layout`. Reading the session's items inside a
/// view makes SwiftUI rebuild that view, the whole transcript and the inspector included, for
/// every phrase added. The feed watches the items itself, outside any view, and publishes a new
/// layout in batches.
@MainActor
@Observable
final class TranscriptFeed {
    private(set) var layout: TranscriptLayout
    @ObservationIgnored private weak var session: Session?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var lastRefresh = ContinuousClock.now

    static let interval: Duration = .milliseconds(300)
    private static var feeds: [ObjectIdentifier: TranscriptFeed] = [:]

    /// The feed for `session`, made on first use.
    static func `for`(_ session: Session) -> TranscriptFeed {
        // A deleted session's address can be reused by a new one: check it's the same object.
        if let feed = feeds[ObjectIdentifier(session)], feed.session === session { return feed }
        let feed = TranscriptFeed(session)
        feeds[ObjectIdentifier(session)] = feed
        return feed
    }

    private init(_ session: Session) {
        self.session = session
        layout = session.layout
        watch()
    }

    private func watch() {
        guard let session else { return }
        withObservationTracking {
            _ = session.items.count
            _ = LayoutRevisions.shared.revision(of: session)
        } onChange: { [weak self] in
            Task { @MainActor in self?.scheduleRefresh() }
        }
    }

    private func scheduleRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            let wait = self.lastRefresh + Self.interval - ContinuousClock.now
            if wait > .zero { try? await Task.sleep(for: wait) }
            self.refreshTask = nil
            self.lastRefresh = .now
            guard let session = self.session, !session.isDeleted else { return }
            self.layout = session.layout
            self.watch()
        }
    }
}

extension Session {
    /// The transcript layout for views: batched, see `TranscriptFeed`.
    @MainActor var feed: TranscriptFeed { TranscriptFeed.for(self) }
}
