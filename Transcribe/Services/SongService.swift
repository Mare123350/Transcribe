import Foundation
import Observation
import SongMatcher
import SwiftData
import TranscribeCore

/// Recognizes songs from the library while they're sung and swaps the messy sung transcription
/// for clean, preloaded lyrics. The sung segments are kept, folded under the song block.
@MainActor
@Observable
final class SongService {
    /// Detections waiting for the operator, newest last. Shown as a "Detected: …" chip.
    private(set) var pendingItemID: UUID?
    private(set) var librarySize = 0

    /// Called when a song starts, so the section classifier can mark the start of worship.
    var onSongStarted: ((TranscriptItem, Session) -> Void)?
    /// Called when a section of a library song is heard: the song, the section's index in the
    /// song, and how sure the match is. Drives the lyrics on the output screen.
    var onSectionSung: ((TranscriptItem, Int, Double) -> Void)?

    private let context: ModelContext
    private var matcher = SongMatcher(songs: [])
    private var tracker = SongTracker()
    private var window: [String] = []
    /// Recent segments (newest last), to find where a song began once it's recognized.
    private var recentSegments: [(id: UUID, tokens: [String])] = []
    /// Recent window matches, to recover sections sung before the song was confirmed.
    private var recentMatches: [SongMatch] = []
    private var currentItemID: UUID?

    init(context: ModelContext) {
        self.context = context
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// A library song is being sung right now.
    var isSinging: Bool { currentItemID != nil }

    // MARK: Library

    /// Adds the bundled hymns the first time the app runs, then builds the matcher.
    func load() {
        // Seed the bundled hymns on first run, after a library update, or if the library is empty.
        let seededKey = "bundledSongsVersion"
        let isEmpty = ((try? context.fetchCount(FetchDescriptor<StoredSong>())) ?? 0) == 0
        if UserDefaults.standard.integer(forKey: seededKey) < 1 || isEmpty,
           let url = Bundle.main.url(forResource: "songs", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let songs = try? SongImporter.songs(fromJSON: data) {
            for record in songs { context.insert(StoredSong(record: record, isBundled: true)) }
            try? context.save()
            UserDefaults.standard.set(1, forKey: seededKey)
        }
        rebuild()
    }

    /// Call after songs are added, edited, or removed.
    func rebuild() {
        let songs = (try? context.fetch(FetchDescriptor<StoredSong>())) ?? []
        matcher = SongMatcher(songs: songs.map(\.record).filter { !$0.sections.isEmpty })
        librarySize = songs.count
    }

    func importSongs(from url: URL) throws -> Int {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let records = try SongImporter.songs(from: url)
        for record in records { context.insert(StoredSong(record: SongRecord(title: record.title, artist: record.artist, sections: record.sections))) }
        try context.save()
        rebuild()
        return records.count
    }

    // MARK: Live

    func reset() {
        tracker.reset()
        window.removeAll()
        recentSegments.removeAll()
        recentMatches.removeAll()
        currentItemID = nil
        pendingItemID = nil
    }

    /// Feeds one finalized segment. Returns true if it was sung (and folded under a song).
    @discardableResult
    func process(_ segment: TranscriptItem, in session: Session) -> Bool {
        guard !matcher.isEmpty else { return false }
        let tokens = TextNormalizer.tokens(segment.text)
        window = Array((window + tokens).suffix(SongMatcher.windowSize))
        recentSegments = Array((recentSegments + [(segment.id, tokens)]).suffix(8))

        tracker.startThreshold = UserDefaults.standard.object(forKey: SettingsKey.songThreshold) as? Double ?? 0.55
        let match = matcher.match(window: window)
        if let match { recentMatches = Array((recentMatches + [match]).suffix(4)) }
        var sung = false
        for event in tracker.update(match, at: now) {
            switch event {
            case .started(let match):
                startSong(match, at: segment, in: session)
                sung = true
            case .sectionChanged(let match):
                appendSection(match)
            case .ended:
                endSong()
            }
        }
        if !sung, let currentItemID, let current = tracker.current {
            if let item = item(currentItemID), let match, match.songID == item.songID {
                item.confidence = max(item.confidence, match.confidence)
            }
            if matcher.segmentBelongs(tokens, to: current.songID) {
                item(currentItemID)?.endTimestamp = segment.endTimestamp
                fold(segment, under: currentItemID)
                sung = true
            }
        }
        return sung
    }

    /// Called every second while recording, so a song ends ~15 s after the singing stops.
    func tick() {
        for event in tracker.tick(at: now) {
            if case .ended = event { endSong() }
        }
    }

    private func startSong(_ match: SongMatch, at segment: TranscriptItem, in session: Session) {
        guard let record = matcher.song(match.songID) else { return }
        // Recent lines that belong to this song were its opening lines.
        let sungLines = recentSegments
            .filter { matcher.segmentBelongs($0.tokens, to: match.songID) || $0.id == segment.id }
            .compactMap { item($0.id) }
            .filter { $0.session === session && $0.kind == .segment }
        let firstSung = sungLines.min { $0.sortIndex < $1.sortIndex } ?? segment

        let song = TranscriptItem(kind: .song, sortIndex: session.sortIndex(before: firstSung), timestamp: firstSung.timestamp)
        song.title = record.title
        song.artist = record.artist
        song.songID = record.id
        song.confidence = match.confidence
        song.status = .detected
        // Sections heard before the song was certain ("Verse 1" while confidence was building).
        var indices: [Int] = []
        for earlier in recentMatches where earlier.songID == match.songID && earlier.confidence >= tracker.continueThreshold {
            if indices.last != earlier.sectionIndex { indices.append(earlier.sectionIndex) }
        }
        if indices.last != match.sectionIndex { indices.append(match.sectionIndex) }
        song.lyricSections = indices.filter { record.sections.indices.contains($0) }.map { record.sections[$0] }
        song.endTimestamp = segment.endTimestamp
        context.insert(song)
        song.session = session
        currentItemID = song.id
        pendingItemID = song.id

        for line in sungLines { fold(line, under: song.id) }
        onSongStarted?(song, session)
        onSectionSung?(song, match.sectionIndex, match.confidence)
    }

    private func appendSection(_ match: SongMatch) {
        guard let currentItemID, let item = item(currentItemID), let record = matcher.song(match.songID),
              record.sections.indices.contains(match.sectionIndex) else { return }
        let section = record.sections[match.sectionIndex]
        if item.lyricSections.last != section {
            item.lyricSections.append(section)
        }
        onSectionSung?(item, match.sectionIndex, match.confidence)
    }

    private func endSong() {
        currentItemID = nil
        window.removeAll()
        recentSegments.removeAll()
        recentMatches.removeAll()
    }

    private func fold(_ segment: TranscriptItem, under parentItemID: UUID) {
        guard UserDefaults.standard.object(forKey: SettingsKey.replaceSungText) as? Bool ?? true else { return }
        segment.parentItemID = parentItemID
        TranscriptLayout.invalidate(segment.session)
    }

    // MARK: Operator actions

    func confirm(_ item: TranscriptItem) {
        item.status = .confirmed
        if pendingItemID == item.id { pendingItemID = nil }
    }

    /// The detection was wrong: put the sung text back and forget the song for a few minutes.
    func dismiss(_ item: TranscriptItem) {
        if let songID = item.songID { tracker.dismiss(songID, at: now) }
        for segment in item.session?.items ?? [] where segment.parentItemID == item.id {
            segment.parentItemID = nil
            TranscriptLayout.invalidate(segment.session)
        }
        if currentItemID == item.id { currentItemID = nil }
        if pendingItemID == item.id { pendingItemID = nil }
        context.delete(item)
    }

    /// The operator says it's a different song.
    func change(_ item: TranscriptItem, to song: StoredSong) {
        if let old = item.songID { tracker.dismiss(old, at: now) }
        item.title = song.title
        item.artist = song.artist
        item.songID = song.id
        item.lyricSections = song.sections
        item.confidence = 1
        item.status = .confirmed
        if pendingItemID == item.id { pendingItemID = nil }
        if currentItemID == item.id {
            tracker.force(SongMatch(songID: song.id, title: song.title, sectionIndex: 0, sectionName: song.sections.first?.name ?? "", confidence: 1), at: now)
        }
    }

    /// Inserts a song by hand (from the library) at the end of the transcript.
    func insert(_ song: StoredSong, in session: Session, at time: TimeInterval) {
        let item = TranscriptItem(kind: .song, sortIndex: session.nextSortIndex, timestamp: time)
        item.title = song.title
        item.artist = song.artist
        item.songID = song.id
        item.lyricSections = song.sections
        item.confidence = 1
        item.status = .confirmed
        context.insert(item)
        item.session = session
    }

    /// Items this service has looked up, so the main thread doesn't run a fetch per lookup.
    private var known: [UUID: TranscriptItem] = [:]

    private func item(_ id: UUID) -> TranscriptItem? {
        if let cached = known[id], !cached.isDeleted, cached.modelContext != nil { return cached }
        let found = try? context.fetch(FetchDescriptor<TranscriptItem>(predicate: #Predicate { $0.id == id })).first
        known[id] = found
        return found
    }
}
