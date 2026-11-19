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
    /// For finding songs by title, lyric, author or number as the operator types.
    private(set) var searchIndex = SongSearchIndex([])
    /// The library by id, so results and Recent don't fetch from the store on every redraw.
    @ObservationIgnored private var songsByID: [UUID: StoredSong] = [:]

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
    /// When the last finished phrase ended: in-progress singing started after it.
    private var lastSegmentEnd: TimeInterval = 0
    /// How many in-progress words were last matched, so the tracker only hears new evidence.
    private var partialWordsMatched = 0

    init(context: ModelContext) {
        self.context = context
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// A library song is being sung right now.
    var isSinging: Bool { currentItemID != nil }

    // MARK: - Library

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
        searchIndex = SongSearchIndex(songs.map { SongSearchEntry(record: $0.record, isFavorite: $0.isFavorite) })
        songsByID = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        librarySize = songs.count
    }

    func importSongs(from url: URL) throws -> Int {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let records = try SongImporter.songs(from: url)
        // New ids, so importing the same file twice doesn't clash with songs already here.
        for record in records {
            context.insert(StoredSong(record: SongRecord(title: record.title, artist: record.artist, sections: record.sections,
                                                         ccliNumber: record.ccliNumber, copyright: record.copyright, themes: record.themes)))
        }
        try context.save()
        rebuild()
        return records.count
    }

    /// Songs matching what the operator typed, best first.
    func search(_ query: String, limit: Int = 8) -> [(song: StoredSong, result: SongSearchResult)] {
        searchIndex.search(query, limit: limit).compactMap { result in song(result.id).map { ($0, result) } }
    }

    func song(_ id: UUID) -> StoredSong? {
        if let cached = songsByID[id] { return cached.isDeleted ? nil : cached }
        return try? context.fetch(FetchDescriptor<StoredSong>(predicate: #Predicate { $0.id == id })).first
    }

    // MARK: - Live

    func reset() {
        tracker.reset()
        window.removeAll()
        recentSegments.removeAll()
        recentMatches.removeAll()
        currentItemID = nil
        pendingItemID = nil
        lastSegmentEnd = 0
        partialWordsMatched = 0
    }

    /// Feeds one finalized segment. Returns true if it was sung (and folded under a song).
    @discardableResult
    func process(_ segment: TranscriptItem, in session: Session) async -> Bool {
        guard !matcher.isEmpty else { return false }
        let tokens = TextNormalizer.tokens(segment.text)
        window = Array((window + tokens).suffix(SongMatcher.windowSize))
        recentSegments = Array((recentSegments + [(segment.id, tokens)]).suffix(8))
        lastSegmentEnd = max(lastSegmentEnd, segment.endTimestamp)
        // The phrase now finished was the in-progress text; what follows starts a new count.
        partialWordsMatched = 0

        tracker.startThreshold = UserDefaults.standard.object(forKey: SettingsKey.songThreshold) as? Double ?? 0.55
        // Matching runs off the main thread; the library can be large.
        let matcher = self.matcher, window = self.window
        let match = await Task.detached(priority: .userInitiated) { matcher.match(window: window) }.value
        if let match { recentMatches = Array((recentMatches + [match]).suffix(4)) }
        var sung = false
        for event in tracker.update(match, at: now) {
            switch event {
            case .started(let match):
                startSong(match, firstSung: segment, at: segment.timestamp, until: segment.endTimestamp, in: session)
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

    /// Matches the words still being recognized. While people sing, the recognizer can hold a
    /// line as in-progress text for many seconds before finishing it; matching only finished
    /// phrases made the song card wait for that, then for a second phrase to confirm it.
    /// The tracker is only told about a match when at least four new words back it, so a
    /// song below the strong threshold still needs two separate pieces of evidence.
    func processPartial(_ text: String, in session: Session, at time: TimeInterval) async {
        guard !matcher.isEmpty else { return }
        let tokens = TextNormalizer.tokens(text)
        // A shorter text is a new utterance after a finished phrase.
        if tokens.count < partialWordsMatched { partialWordsMatched = 0 }
        guard tokens.count >= partialWordsMatched + 4 else { return }
        partialWordsMatched = tokens.count

        tracker.startThreshold = UserDefaults.standard.object(forKey: SettingsKey.songThreshold) as? Double ?? 0.55
        let matcher = self.matcher, window = Array((self.window + tokens).suffix(SongMatcher.windowSize))
        // Also the line being sung on its own: the words spoken before a song (the welcome, "let's
        // stand") fill the shared window and hold its score down until enough lyrics push them out.
        let line = tokens.count >= 8 ? Array(tokens.suffix(SongMatcher.windowSize)) : nil
        let match = await Task.detached(priority: .userInitiated) {
            [matcher.match(window: window), line.flatMap { matcher.match(window: $0) }]
                .compactMap { $0 }.max { $0.confidence < $1.confidence }
        }.value
        // A finished phrase may have arrived while matching; its result is newer than this one.
        guard partialWordsMatched == tokens.count else { return }
        if let match { recentMatches = Array((recentMatches + [match]).suffix(4)) }
        for event in tracker.update(match, at: now) {
            switch event {
            case .started(let match):
                startSong(match, firstSung: nil, at: max(lastSegmentEnd, 0), until: time, in: session)
            case .sectionChanged(let match):
                appendSection(match)
            case .ended:
                endSong()
            }
        }
        if let currentItemID, let item = item(currentItemID), let match, match.songID == item.songID {
            item.confidence = max(item.confidence, match.confidence)
            item.endTimestamp = max(item.endTimestamp, time)
        }
    }

    /// Called every second while recording, so a song ends ~15 s after the singing stops.
    func tick() {
        for event in tracker.tick(at: now) {
            if case .ended = event { endSong() }
        }
    }

    /// Starts a song card. `segment` is the finished phrase that confirmed it, or nil when the
    /// in-progress text did; then the card goes at `time`, unless earlier finished lines belong.
    private func startSong(_ match: SongMatch, firstSung segment: TranscriptItem?, at time: TimeInterval, until end: TimeInterval, in session: Session) {
        guard let record = matcher.song(match.songID) else { return }
        // Recent lines that belong to this song were its opening lines.
        let sungLines = recentSegments
            .filter { matcher.segmentBelongs($0.tokens, to: match.songID) || $0.id == segment?.id }
            .compactMap { item($0.id) }
            .filter { $0.session === session && $0.kind == .segment }
        let firstSung = sungLines.min { $0.sortIndex < $1.sortIndex } ?? segment

        let song = TranscriptItem(kind: .song,
                                  sortIndex: firstSung.map { session.sortIndex(before: $0) } ?? session.sortIndex(at: time, after: true),
                                  timestamp: firstSung?.timestamp ?? time)
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
        song.endTimestamp = end
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

    // MARK: - Operator actions

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
