import Foundation
import Observation
import ScriptureDetector
import SwiftData
import TranscribeCore

/// Watches finalized transcript text for scripture and inserts verse callouts.
///
/// - An explicit reference ("John 3:16") creates a callout straight away in the default version.
///   The words that follow are then compared with every installed translation to work out which
///   one is being read, updating the callout until enough of the passage has been heard.
/// - A verse quoted without a reference is found through the quote index.
/// - A version named aloud ("in the NIV…") overrides the scoring.
@MainActor
@Observable
final class ScriptureService {
    private(set) var translations: [TranslationInfo] = []
    private(set) var isQuoteIndexReady = false
    private(set) var loadError: String?

    private let detector = ScriptureDetector(translations: [])
    private let context: ModelContext

    /// Verses whose version is still being worked out from what's said next.
    private var listening: [UUID: Listening] = [:]
    /// Recently detected passages, so one passage read over several segments isn't added twice.
    private var recent: [(key: String, at: Date, itemID: UUID)] = []
    private var previousSegment: (text: String, time: TimeInterval)?
    private var recentWords: [String] = []

    private struct Listening {
        let itemID: UUID
        let reference: BibleReference
        let startedAt: TimeInterval
        let verseWordCount: Int
        var heard: String
        var namedVersion: String?
        /// Segments that were the passage being read, folded under the callout.
        var reading: [String] = []
    }

    static let listenWindow: TimeInterval = 60

    /// Called the first time a referenced passage is heard being read aloud.
    var onPassageRead: ((TranscriptItem, Session) -> Void)?

    init(context: ModelContext) {
        self.context = context
    }

    nonisolated static var importedDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Transcribe/Translations", directoryHint: .isDirectory)
    }

    var defaultAbbreviation: String {
        let stored = UserDefaults.standard.string(forKey: SettingsKey.defaultTranslation) ?? "KJV"
        return translations.contains { $0.abbreviation == stored } ? stored : (translations.first?.abbreviation ?? "KJV")
    }

    // MARK: Loading

    func load() async {
        let bundled = (Bundle.main.urls(forResourcesWithExtension: "sqlite", subdirectory: nil) ?? [])
            + (Bundle.main.urls(forResourcesWithExtension: "sqlite", subdirectory: "Bibles") ?? [])
        let loaded = await Task.detached {
            TranslationLibrary.load(bundled: bundled, importedDirectory: Self.importedDirectory)
        }.value
        await detector.replaceTranslations(loaded)
        translations = loaded.map(\.info)
        loadError = loaded.isEmpty ? "No Bible translations could be loaded." : nil
        isQuoteIndexReady = false
        await detector.prepareQuoteIndex()
        isQuoteIndexReady = await detector.isQuoteIndexReady
    }

    func importTranslation(from url: URL) async throws {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let existing = Set(translations.map(\.id))
        _ = try await Task.detached {
            try TranslationLibrary.importTranslation(from: url, into: Self.importedDirectory, existingIDs: existing)
        }.value
        await load()
    }

    func removeTranslation(_ info: TranslationInfo) async {
        guard !info.isBundled else { return }
        try? FileManager.default.removeItem(at: Self.importedDirectory.appending(path: "\(info.id).sqlite"))
        await load()
    }

    func text(of reference: BibleReference, abbreviation: String) async -> String? {
        await detector.passage(reference, abbreviation: abbreviation)
    }

    // MARK: Live detection

    func reset() {
        listening.removeAll()
        recent.removeAll()
        previousSegment = nil
        recentWords.removeAll()
    }

    /// Handles one finalized segment. Sung segments (inside a song) are ignored.
    func process(_ segment: TranscriptItem, in session: Session) async {
        let text = segment.text
        let time = segment.timestamp
        let previous = previousSegment
        previousSegment = (text, segment.endTimestamp)
        recent.removeAll { Date.now.timeIntervalSince($0.at) > 180 }

        await feedListeners(segment)

        // A reference can be split across two segments ("John chapter 3" … "verse 16").
        var detections = detector.references(in: text)
        if let previous, time - previous.time < 8 {
            let joined = detector.references(in: previous.text + " " + text)
            let alone = Set(detector.references(in: previous.text).map(\.reference.key))
            for detection in joined where !alone.contains(detection.reference.key) && !detections.contains(where: { $0.reference == detection.reference }) {
                detections.append(detection)
            }
        }

        let named = detector.namedVersion(in: text)
        for detection in detections where detection.confidence >= 0.5 {
            await addReference(detection, after: segment, in: session, namedVersion: named)
        }

        if UserDefaults.standard.object(forKey: SettingsKey.detectQuotes) as? Bool ?? true {
            recentWords = Array((recentWords + TextNormalizer.tokens(text)).suffix(45))
            await detectQuotes(after: segment, in: session, previousText: previous?.text)
        }
    }

    private func addReference(_ detection: DetectedReference, after segment: TranscriptItem, in session: Session, namedVersion: String?) async {
        let reference = detection.reference

        // "John 3" then "verse 16" a moment later: upgrade the chapter-only callout.
        if let chapterOnly = recent.first(where: { $0.key == "\(reference.book).\(reference.chapter)" }),
           !reference.isWholeChapter,
           let item = item(chapterOnly.itemID), segment.timestamp - item.timestamp < 20 {
            remove(item)
        }
        guard !recent.contains(where: { $0.key == reference.key }) else { return }

        let item = TranscriptItem(kind: .verse, sortIndex: session.sortIndex(after: segment), timestamp: segment.timestamp)
        item.verseSource = .reference
        item.reference = reference.description
        item.referenceKey = reference.key
        item.referenceConfidence = detection.confidence
        item.referenceNote = detection.reasons.joined(separator: " ")
        item.alternatives = detection.alternatives
        context.insert(item)
        item.session = session
        recent.append((reference.key, .now, item.id))

        let abbreviation = defaultAbbreviation
        item.versionAbbreviation = abbreviation
        item.verseText = await detector.passage(reference, abbreviation: abbreviation) ?? ""
        let verseWords = TextNormalizer.tokens(item.verseText).count

        // Some speakers quote the verse in the same breath as the reference.
        let sameSegmentTail = segment.text
        listening[item.id] = Listening(itemID: item.id, reference: reference, startedAt: segment.timestamp, verseWordCount: max(verseWords, 1), heard: sameSegmentTail, namedVersion: namedVersion)
        await rescore(item.id)
    }

    private func feedListeners(_ segment: TranscriptItem) async {
        let text = segment.text
        let named = detector.namedVersion(in: text)
        for id in Array(listening.keys) {
            guard var state = listening[id] else { continue }
            if segment.timestamp - state.startedAt > Self.listenWindow {
                settle(id)
                continue
            }
            state.heard += " " + text
            if let named { state.namedVersion = named }
            // A segment that is mostly the passage itself is the reading: fold it into the callout.
            if let callout = item(id) {
                let alignment = VersionScorer.align(spoken: TextNormalizer.tokens(text), verse: TextNormalizer.tokens(callout.verseText))
                if alignment.matched >= 5 && alignment.precision >= 0.6 {
                    segment.parentItemID = id
                    state.reading.append(text)
                    if state.reading.count == 1, let session = segment.session { onPassageRead?(callout, session) }
                }
            }
            listening[id] = state
            await rescore(id)
        }
    }

    private func rescore(_ id: UUID) async {
        guard let state = listening[id], let item = item(id) else {
            listening[id] = nil
            return
        }
        let scores = await detector.scoreVersions(spoken: state.heard, reference: state.reference, preferred: defaultAbbreviation)
        item.versionScores = scores.map { VersionScoreValue(abbreviation: $0.abbreviation, score: $0.score) }

        if let named = state.namedVersion {
            item.versionNamedBySpeaker = true
            item.versionAbbreviation = named
            if let text = await detector.passage(state.reference, abbreviation: named) {
                item.verseText = text
                item.confidence = scores.first { $0.abbreviation == named }?.score ?? 1
            } else {
                // Named but not installed (e.g. NIV): show the reference and the spoken words.
                item.verseText = ""
                item.confidence = 1
            }
        } else if let best = scores.first, best.matchedWords >= 3 {
            if best.abbreviation != item.versionAbbreviation {
                item.versionAbbreviation = best.abbreviation
                item.verseText = await detector.passage(state.reference, abbreviation: best.abbreviation) ?? item.verseText
            }
            item.confidence = best.score
        }
        item.spokenText = state.reading.isEmpty
            ? Self.trim(state.heard, maxWords: state.verseWordCount * 2 + 12)
            : state.reading.joined(separator: " ")

        // Enough of the passage has been heard to settle the version.
        if let best = scores.first, best.matchedWords >= max(4, state.verseWordCount * 7 / 10) {
            settle(id)
        }
    }

    private func settle(_ id: UUID) {
        listening[id] = nil
        item(id)?.versionSettled = true
    }

    private func detectQuotes(after segment: TranscriptItem, in session: Session, previousText: String?) async {
        guard isQuoteIndexReady, recentWords.count >= 8 else { return }
        let window = recentWords.joined(separator: " ")
        for match in await detector.quotedVerses(in: window) {
            let key = match.reference.key
            // Already on screen from an explicit reference, or just added.
            let covered = recent.contains { entry in
                entry.key == key || item(entry.itemID).flatMap(\.bibleReference).map { ref in
                    ref.book == match.reference.book && ref.chapter == match.reference.chapter
                        && (ref.isWholeChapter || (ref.verseNumbers.lowerBound - 2...ref.verseNumbers.upperBound + 2).contains(match.reference.verseStart ?? 0))
                } == true
            }
            guard !covered else { continue }

            let item = TranscriptItem(kind: .verse, sortIndex: session.sortIndex(after: segment), timestamp: segment.timestamp)
            item.verseSource = .quote
            item.reference = match.reference.description
            item.referenceKey = key
            item.referenceConfidence = match.best.score
            item.versionAbbreviation = match.best.abbreviation
            item.verseText = await detector.passage(match.reference, abbreviation: match.best.abbreviation) ?? ""
            item.confidence = match.best.score
            item.versionScores = match.scores.map { VersionScoreValue(abbreviation: $0.abbreviation, score: $0.score) }
            // Show what was actually said, with its original wording and punctuation.
            let ownWords = VersionScorer.align(spoken: TextNormalizer.tokens(segment.text), verse: TextNormalizer.tokens(item.verseText)).matched
            item.spokenText = ownWords >= 5 || previousText == nil ? segment.text : (previousText! + " " + segment.text)
            item.versionSettled = true
            context.insert(item)
            item.session = session
            recent.append((key, .now, item.id))
            recentWords.removeAll()
        }
    }

    // MARK: Operator actions

    /// ⌘B: adds a verse the operator typed.
    func insertManual(_ reference: BibleReference, abbreviation: String, in session: Session, at time: TimeInterval) async {
        let item = TranscriptItem(kind: .verse, sortIndex: session.nextSortIndex, timestamp: time)
        item.verseSource = .manual
        item.reference = reference.description
        item.referenceKey = reference.key
        item.versionAbbreviation = abbreviation
        item.verseText = await detector.passage(reference, abbreviation: abbreviation) ?? ""
        item.confidence = 1
        item.status = .confirmed
        item.versionSettled = true
        context.insert(item)
        item.session = session
    }

    /// Removes a callout and puts any reading folded under it back into the transcript.
    func remove(_ item: TranscriptItem) {
        listening[item.id] = nil
        for child in item.session?.items ?? [] where child.parentItemID == item.id {
            child.parentItemID = nil
        }
        recent.removeAll { $0.itemID == item.id }
        context.delete(item)
    }

    func changeVersion(of item: TranscriptItem, to abbreviation: String) async {
        guard let reference = item.bibleReference else { return }
        listening[item.id] = nil
        item.versionAbbreviation = abbreviation
        item.verseText = await detector.passage(reference, abbreviation: abbreviation) ?? ""
        item.confidence = item.versionScores.first { $0.abbreviation == abbreviation }?.score ?? item.confidence
        item.versionNamedBySpeaker = false
        item.versionSettled = true
        item.status = .confirmed
    }

    func changeReference(of item: TranscriptItem, to reference: BibleReference) async {
        listening[item.id] = nil
        item.reference = reference.description
        item.referenceKey = reference.key
        item.alternatives = []
        item.referenceConfidence = 1
        item.referenceNote = ""
        item.verseText = await detector.passage(reference, abbreviation: item.versionAbbreviation) ?? ""
        item.status = .confirmed
    }

    // MARK: Helpers

    private func item(_ id: UUID) -> TranscriptItem? {
        try? context.fetch(FetchDescriptor<TranscriptItem>(predicate: #Predicate { $0.id == id })).first
    }

    private static func trim(_ text: String, maxWords: Int) -> String {
        let words = text.split(separator: " ")
        return words.count <= maxWords ? text.trimmingCharacters(in: .whitespaces) : words.prefix(maxWords).joined(separator: " ") + "…"
    }
}
