import Foundation
import TranscribeCore

/// A verse recognized from its wording alone.
public struct QuoteMatch: Sendable, Hashable {
    public let reference: BibleReference
    public let scores: [VersionScore]
    public var best: VersionScore { scores[0] }
}

/// Everything scripture-related: explicit references, quoted verses, and which version was read.
public actor ScriptureDetector {
    public private(set) var translations: [BibleTranslation]
    private var quoteIndex: QuoteIndex?

    public init(translations: [BibleTranslation]) {
        self.translations = translations
    }

    public var infos: [TranslationInfo] { translations.map(\.info) }
    public var isQuoteIndexReady: Bool { quoteIndex != nil }

    public func replaceTranslations(_ translations: [BibleTranslation]) {
        self.translations = translations
        quoteIndex = nil
    }

    /// Builds (or loads from `cacheDirectory`) the quote index. The work runs off this actor, so
    /// references and passages keep working while it's prepared.
    public func prepareQuoteIndex(cacheDirectory: URL? = nil) async {
        guard quoteIndex == nil else { return }
        let translations = self.translations
        let index = await Task.detached(priority: .utility) {
            QuoteIndex.loadOrBuild(translations: translations, cacheDirectory: cacheDirectory)
        }.value
        // The translations may have changed (an import) while it was building.
        guard self.translations.map(\.info.id) == translations.map(\.info.id), quoteIndex == nil else { return }
        quoteIndex = index
    }

    // MARK: References

    public nonisolated func references(in text: String, context: BibleReference? = nil) -> [DetectedReference] {
        ReferenceParser.parse(text, context: context)
    }

    public nonisolated func namedVersion(in text: String) -> String? {
        VersionNameDetector.detect(in: text)
    }

    public func translation(abbreviation: String) -> BibleTranslation? {
        translations.first { $0.info.abbreviation.caseInsensitiveCompare(abbreviation) == .orderedSame }
    }

    public func verses(_ reference: BibleReference, abbreviation: String) -> [Verse] {
        translation(abbreviation: abbreviation)?.verses(of: reference) ?? []
    }

    public func passage(_ reference: BibleReference, abbreviation: String) -> String? {
        translation(abbreviation: abbreviation)?.text(of: reference)
    }

    /// The passage in the requested version if it's installed; otherwise in the default, then the
    /// fallback order. `choice.source == .online` means the caller should fetch it from a provider.
    public func resolvedPassage(_ reference: BibleReference, requested: String?, defaultVersion: String, order: [String], online: [String] = []) -> (choice: TranslationChoice, text: String?) {
        let choice = TranslationResolver.resolve(
            requested: requested, installed: translations.map(\.info.abbreviation), online: online,
            defaultVersion: defaultVersion, order: order,
            hasPassage: { self.translation(abbreviation: $0)?.text(of: reference) != nil }
        )
        switch choice.source {
        case .installed, .fallback: return (choice, passage(reference, abbreviation: choice.shown))
        case .online, .missing: return (choice, nil)
        }
    }

    /// Scores what was said against every installed translation of `reference`, best first.
    /// `preferred` wins ties (e.g. the church's usual version).
    public func scoreVersions(spoken: String, reference: BibleReference, preferred: String? = nil) -> [VersionScore] {
        var candidates = translations.compactMap { translation in translation.text(of: reference).map { (translation.info, $0) } }
        if let preferred, let index = candidates.firstIndex(where: { $0.0.abbreviation == preferred }) {
            candidates.insert(candidates.remove(at: index), at: 0)
        }
        return VersionScorer.rank(spoken: spoken, candidates: candidates)
    }

    // MARK: Quotes

    /// Verses quoted in `text` without a reference. Requires a good run of the verse's own words,
    /// so ordinary sermon language doesn't trigger it.
    public func quotedVerses(in text: String, minimumWords: Int = 8, minimumScore: Double = 0.5) -> [QuoteMatch] {
        guard let quoteIndex else { return [] }
        let tokens = TextNormalizer.tokens(text)
        var matches: [QuoteMatch] = []
        for candidate in quoteIndex.candidates(for: tokens) {
            let scores = scoreVersions(spoken: text, reference: candidate.reference)
            guard let best = scores.first else { continue }
            let verseLength = translations.first.flatMap { $0.text(of: candidate.reference) }.map { TextNormalizer.tokens($0).count } ?? 0
            let enough = best.matchedWords >= min(minimumWords, max(5, verseLength * 3 / 4))
            if enough && best.score >= minimumScore {
                matches.append(QuoteMatch(reference: candidate.reference, scores: scores))
            }
        }
        // Neighbouring verses often share phrases (John 3:15 and 3:16). Keep the strongest of each cluster.
        var kept: [QuoteMatch] = []
        for match in matches.sorted(by: { $0.best.score > $1.best.score }) {
            let shadowed = kept.contains { other in
                other.reference.book == match.reference.book && other.reference.chapter == match.reference.chapter
                    && abs((other.reference.verseStart ?? 0) - (match.reference.verseStart ?? 0)) <= 2
            }
            if !shadowed { kept.append(match) }
        }
        return Array(kept.prefix(2))
    }
}
