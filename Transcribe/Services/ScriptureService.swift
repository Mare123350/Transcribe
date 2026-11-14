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
    /// Versions available from online providers the user has a key for.
    private(set) var onlineVersions: [OnlineVersion] = []
    /// The last problem fetching from an online provider, shown in Settings.
    private(set) var onlineError: String?
    let online: OnlineBibleService
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
    /// The passage being discussed, so "the next verse" and "verse 18" can be understood.
    private var lastReference: (reference: BibleReference, time: TimeInterval)?
    static let contextWindow: TimeInterval = 180
    /// A card shown from in-progress text before the phrase is finished. The finished segment
    /// adopts it (moving and correcting it) or removes it.
    private var provisional: (itemID: UUID, key: String)?
    private var lastPartial = ""

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
        let defaults = UserDefaults.standard
        let deviceID = defaults.string(forKey: SettingsKey.providerDeviceID) ?? {
            let id = UUID().uuidString
            defaults.set(id, forKey: SettingsKey.providerDeviceID)
            return id
        }()
        let cacheURL = URL.applicationSupportDirectory.appending(path: "Transcribe/OnlineVerseCache.sqlite")
        let cache = (try? OnlineVerseCache(url: cacheURL)) ?? (try! OnlineVerseCache(url: nil))
        self.online = OnlineBibleService(credentials: KeychainCredentialStore(), cache: cache, apiBibleVersions: Self.storedAPIBibleVersions, deviceID: deviceID)
    }

    static var storedAPIBibleVersions: [OnlineVersion] {
        UserDefaults.standard.data(forKey: SettingsKey.apiBibleVersions).flatMap { try? JSONDecoder().decode([OnlineVersion].self, from: $0) } ?? []
    }

    /// Re-reads which online versions can be used (after a key or version choice changes).
    func refreshOnline() async {
        await online.setAPIBibleVersions(Self.storedAPIBibleVersions)
        onlineVersions = await online.availableVersions()
    }

    /// Abbreviations tried after the default when a passage is missing, in the user's order.
    var fallbackOrder: [String] {
        (UserDefaults.standard.string(forKey: SettingsKey.translationOrder) ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Every version the operator can pick: installed first, then online.
    var allVersionNames: [(abbreviation: String, name: String, isOnline: Bool)] {
        translations.map { ($0.abbreviation, $0.name, false) }
            + onlineVersions.filter { version in !translations.contains { $0.abbreviation.caseInsensitiveCompare(version.abbreviation) == .orderedSame } }
                .map { ($0.abbreviation, "\($0.name) (online)", true) }
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
        await refreshOnline()
        isQuoteIndexReady = false
        await detector.prepareQuoteIndex(cacheDirectory: URL.cachesDirectory.appending(path: "Transcribe", directoryHint: .isDirectory))
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

    /// Reads files chosen for import (one file, several files, or a folder) without installing.
    func parseImport(_ urls: [URL]) async throws -> ParsedTranslation {
        let accessing = urls.map { $0.startAccessingSecurityScopedResource() }
        defer { for (url, ok) in zip(urls, accessing) where ok { url.stopAccessingSecurityScopedResource() } }
        return try await Task.detached { try TranslationImporter.parse(urls) }.value
    }

    func install(_ parsed: ParsedTranslation, abbreviation: String, name: String, license: String) async throws {
        let existing = Set(translations.map(\.id))
        _ = try await Task.detached {
            try TranslationImporter.install(parsed, abbreviation: abbreviation, name: name, license: license, into: Self.importedDirectory, existingIDs: existing)
        }.value
        await load()
    }

    // MARK: Online providers

    func hasKey(_ provider: OnlineProviderID) -> Bool { KeychainCredentialStore().key(for: provider) != nil }

    /// Checks the key with the provider, then keeps it in the Keychain. For API.Bible, returns
    /// the English versions the key can use.
    func saveKey(_ key: String, for provider: OnlineProviderID) async throws -> [OnlineVersion] {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let versions = try await online.verify(provider, key: trimmed)
        try KeychainCredentialStore().setKey(trimmed, for: provider)
        await refreshOnline()
        return versions
    }

    func removeKey(_ provider: OnlineProviderID) async {
        try? KeychainCredentialStore().setKey(nil, for: provider)
        if provider == .apiBible { setAPIBibleVersions([]) }
        await refreshOnline()
    }

    func setAPIBibleVersions(_ versions: [OnlineVersion]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(versions), forKey: SettingsKey.apiBibleVersions)
        Task { await refreshOnline() }
    }

    func removeTranslation(_ info: TranslationInfo) async {
        guard !info.isBundled else { return }
        try? FileManager.default.removeItem(at: Self.importedDirectory.appending(path: "\(info.id).sqlite"))
        await load()
    }

    func text(of reference: BibleReference, abbreviation: String) async -> String? {
        if let text = await detector.passage(reference, abbreviation: abbreviation) { return text }
        guard onlineVersions.contains(where: { $0.abbreviation.caseInsensitiveCompare(abbreviation) == .orderedSame }) else { return nil }
        return try? await online.passage(reference, abbreviation: abbreviation).text
    }

    /// Fills a callout's text: the requested version if it's installed or online, otherwise the
    /// default (then the fallback order), labelled "NIV requested, showing KJV".
    func show(_ item: TranscriptItem, reference: BibleReference, requested: String?) async {
        let onlineNames = onlineVersions.map(\.abbreviation)
        let resolved = await detector.resolvedPassage(reference, requested: requested, defaultVersion: defaultAbbreviation, order: fallbackOrder, online: onlineNames)
        guard resolved.choice.source == .online else {
            apply(resolved, to: item)
            return
        }
        // Show an installed version straight away, then swap in the online text when it arrives.
        if item.verseText.isEmpty {
            apply(await detector.resolvedPassage(reference, requested: requested, defaultVersion: defaultAbbreviation, order: fallbackOrder), to: item)
        }
        do {
            let passage = try await online.passage(reference, abbreviation: resolved.choice.shown)
            item.versionAbbreviation = passage.version.abbreviation
            item.requestedVersion = ""
            item.verseText = passage.text
            item.verseCopyright = passage.copyright
            onlineError = nil
        } catch {
            onlineError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            apply(await detector.resolvedPassage(reference, requested: requested, defaultVersion: defaultAbbreviation, order: fallbackOrder), to: item)
        }
    }

    private func apply(_ resolved: (choice: TranslationChoice, text: String?), to item: TranscriptItem) {
        item.versionAbbreviation = resolved.choice.shown
        item.requestedVersion = resolved.choice.requested ?? ""
        item.verseText = resolved.text ?? ""
        item.verseCopyright = ""
    }

    // MARK: Live detection

    func reset() {
        listening.removeAll()
        provisional = nil
        lastPartial = ""
        recent.removeAll()
        previousSegment = nil
        recentWords.removeAll()
        lastReference = nil
    }

    /// Looks for a reference in the words still being spoken, so its card appears mid-sentence.
    /// Only confident, explicit references; the finished segment confirms or corrects it.
    func processPartial(_ text: String, in session: Session) async {
        guard text != lastPartial else { return }
        lastPartial = text
        if let last = lastReference, session.duration - last.time > Self.contextWindow { lastReference = nil }
        let found = detector.references(in: text, context: lastReference?.reference)
            .filter { $0.confidence >= 0.75 && $0.form == .absolute }
        guard let detection = found.last else { return }
        let reference = detection.reference
        let named = detector.namedVersion(in: text)

        if let current = provisional, let item = item(current.itemID) {
            // "John 3" became "John 3:16" as the speaker went on.
            guard current.key != reference.key else { return }
            provisional = (current.itemID, reference.key)
            item.reference = reference.description
            item.referenceKey = reference.key
            await show(item, reference: reference, requested: named)
            return
        }
        guard !recent.contains(where: { $0.key == reference.key }) else { return }

        let item = TranscriptItem(kind: .verse, sortIndex: session.nextSortIndex, timestamp: session.duration)
        item.verseSource = .reference
        item.reference = reference.description
        item.referenceKey = reference.key
        item.referenceConfidence = detection.confidence
        context.insert(item)
        item.session = session
        known[item.id] = item
        provisional = (item.id, reference.key)
        await show(item, reference: reference, requested: named)
    }

    /// The card shown from in-progress text, moved to just after the segment that finished it.
    private func adoptProvisional(after segment: TranscriptItem, in session: Session) -> TranscriptItem? {
        guard let current = provisional else { return nil }
        provisional = nil
        guard let item = item(current.itemID) else { return nil }
        item.sortIndex = session.sortIndex(after: segment)
        item.timestamp = segment.timestamp
        TranscriptLayout.invalidate(session)
        return item
    }

    /// Handles one finalized segment. Sung segments (inside a song) are ignored.
    func process(_ segment: TranscriptItem, in session: Session) async {
        lastPartial = ""
        defer {
            // The finished words had no reference after all: take the early card away.
            if let leftover = provisional {
                provisional = nil
                if let item = item(leftover.itemID) { remove(item) }
            }
        }
        let text = segment.text
        let time = segment.timestamp
        let previous = previousSegment
        previousSegment = (text, segment.endTimestamp)
        recent.removeAll { Date.now.timeIntervalSince($0.at) > 180 }

        // "The next verse", "verse 18": read against the passage being discussed.
        if let last = lastReference, time - last.time > Self.contextWindow { lastReference = nil }
        let contextReference = lastReference?.reference

        // A reference can be split across two segments ("John chapter 3" … "verse 16").
        var detections = detector.references(in: text, context: contextReference)
        if UserDefaults.standard.object(forKey: SettingsKey.rewriteReferences) as? Bool ?? true {
            let rewritten = ReferenceParser.rewrite(text, references: detections)
            if rewritten != text {
                if segment.originalText.isEmpty { segment.originalText = text }
                segment.text = rewritten
            }
        }
        if let previous, time - previous.time < 8 {
            let joined = detector.references(in: previous.text + " " + text, context: contextReference)
            let alone = Set(detector.references(in: previous.text).map(\.reference.key))
            // Only references said across the break; relative ones were already read above.
            for detection in joined where detection.form == .absolute && !alone.contains(detection.reference.key) && !detections.contains(where: { $0.reference == detection.reference }) {
                detections.append(detection)
            }
        }

        // A version named alongside a new reference belongs to that reference, not to earlier ones.
        await feedListeners(segment, namedVersionApplies: detections.isEmpty)

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
        // The same passage again is the reading continuing, unless a different version is named.
        let repeated = recent.filter { $0.key == reference.key }.compactMap { item($0.itemID) }
        guard repeated.allSatisfy({ previous in
            guard let namedVersion else { return false }
            return previous.versionAbbreviation.caseInsensitiveCompare(namedVersion) != .orderedSame
                && previous.requestedVersion.caseInsensitiveCompare(namedVersion) != .orderedSame
        }) else { return }

        if detection.confidence >= 0.75 { lastReference = (reference, segment.timestamp) }
        let item = adoptProvisional(after: segment, in: session)
            ?? TranscriptItem(kind: .verse, sortIndex: session.sortIndex(after: segment), timestamp: segment.timestamp)
        item.verseSource = .reference
        item.reference = reference.description
        item.referenceKey = reference.key
        item.referenceConfidence = detection.confidence
        item.referenceNote = detection.reasons.joined(separator: " ")
        item.alternatives = detection.alternatives
        context.insert(item)
        item.session = session
        recent.append((reference.key, .now, item.id))

        await show(item, reference: reference, requested: namedVersion)
        if namedVersion != nil { item.versionNamedBySpeaker = true }
        let verseWords = TextNormalizer.tokens(item.verseText).count

        // Some speakers quote the verse in the same breath as the reference.
        let sameSegmentTail = segment.text
        listening[item.id] = Listening(itemID: item.id, reference: reference, startedAt: segment.timestamp, verseWordCount: max(verseWords, 1), heard: sameSegmentTail, namedVersion: namedVersion)
        await rescore(item.id)
    }

    private func feedListeners(_ segment: TranscriptItem, namedVersionApplies: Bool) async {
        let text = segment.text
        let named = namedVersionApplies ? detector.namedVersion(in: text) : nil
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
                    TranscriptLayout.invalidate(segment.session)
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
            let alreadyShown = item.versionAbbreviation.caseInsensitiveCompare(named) == .orderedSame
                || item.requestedVersion.caseInsensitiveCompare(named) == .orderedSame
            // Named but not installed (e.g. NIV): the default is shown, labelled "NIV requested".
            if !alreadyShown || item.verseText.isEmpty { await show(item, reference: state.reference, requested: named) }
            item.confidence = scores.first { $0.abbreviation == item.versionAbbreviation }?.score ?? 1
        } else if let best = scores.first, best.matchedWords >= 3, item.verseCopyright.isEmpty {
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
            lastReference = (match.reference, segment.timestamp)
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
        await show(item, reference: reference, requested: abbreviation)
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
        TranscriptLayout.invalidate(item.session)
        recent.removeAll { $0.itemID == item.id }
        context.delete(item)
    }

    func changeVersion(of item: TranscriptItem, to abbreviation: String) async {
        guard let reference = item.bibleReference else { return }
        listening[item.id] = nil
        await show(item, reference: reference, requested: abbreviation)
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
        await show(item, reference: reference, requested: item.requestedVersion.isEmpty ? item.versionAbbreviation : item.requestedVersion)
        item.status = .confirmed
    }

    // MARK: Helpers

    /// Items this service has looked up, so the main thread doesn't run a fetch per lookup.
    private var known: [UUID: TranscriptItem] = [:]

    private func item(_ id: UUID) -> TranscriptItem? {
        if let cached = known[id], !cached.isDeleted, cached.modelContext != nil { return cached }
        let found = try? context.fetch(FetchDescriptor<TranscriptItem>(predicate: #Predicate { $0.id == id })).first
        known[id] = found
        return found
    }

    private static func trim(_ text: String, maxWords: Int) -> String {
        let words = text.split(separator: " ")
        return words.count <= maxWords ? text.trimmingCharacters(in: .whitespaces) : words.prefix(maxWords).joined(separator: " ") + "…"
    }
}
