import Foundation
import TranscribeCore

public struct VersionScore: Sendable, Hashable {
    public let translationID: String
    public let abbreviation: String
    /// 0…1 similarity between what was said and this translation's wording.
    public let score: Double
    /// Words of the verse heard in order.
    public let matchedWords: Int
}

/// Works out which translation a speaker read from by comparing their words with each version.
public enum VersionScorer {
    public struct Alignment: Sendable, Equatable {
        /// Verse words heard, in order.
        public let matched: Int
        /// Fraction of the verse that was heard.
        public let recall: Double
        /// Fraction of the spoken span (first to last matched word) that belongs to the verse.
        public let precision: Double
        public var f1: Double { recall + precision == 0 ? 0 : 2 * recall * precision / (recall + precision) }
    }

    /// Aligns verse words to spoken words in order (longest common subsequence, tolerant of small
    /// misspellings) and measures how well they line up. Extra words around the quote don't count
    /// against it; gaps inside the quote do.
    public static func align(spoken: [String], verse: [String]) -> Alignment {
        guard !spoken.isEmpty, !verse.isEmpty else { return Alignment(matched: 0, recall: 0, precision: 0) }
        let n = verse.count, m = spoken.count
        var table = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in 1...n {
            for j in 1...m {
                table[i][j] = Similarity.wordsMatch(verse[i - 1], spoken[j - 1]) ? table[i - 1][j - 1] + 1 : max(table[i - 1][j], table[i][j - 1])
            }
        }
        // Walk back to find which spoken words were used.
        var i = n, j = m
        var first = Int.max, last = -1
        while i > 0 && j > 0 {
            if Similarity.wordsMatch(verse[i - 1], spoken[j - 1]) && table[i][j] == table[i - 1][j - 1] + 1 {
                first = min(first, j - 1)
                last = max(last, j - 1)
                i -= 1; j -= 1
            } else if table[i - 1][j] >= table[i][j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }
        let matched = table[n][m]
        guard matched > 0 else { return Alignment(matched: 0, recall: 0, precision: 0) }
        let span = last - first + 1
        return Alignment(matched: matched, recall: Double(matched) / Double(n), precision: Double(matched) / Double(span))
    }

    /// Scores `spoken` against each translation's text of the same passage, best first. Ties keep
    /// the order of `candidates`, so put the preferred default version first.
    public static func rank(spoken: String, candidates: [(TranslationInfo, String)]) -> [VersionScore] {
        let spokenTokens = TextNormalizer.tokens(spoken)
        let scored = candidates.enumerated().map { index, candidate -> (Int, VersionScore) in
            let alignment = align(spoken: spokenTokens, verse: TextNormalizer.tokens(candidate.1))
            return (index, VersionScore(translationID: candidate.0.id, abbreviation: candidate.0.abbreviation, score: alignment.f1, matchedWords: alignment.matched))
        }
        return scored.sorted { ($0.1.score, -$0.0) > ($1.1.score, -$1.0) }.map(\.1)
    }
}

/// Spots a speaker naming a translation: "in the NIV it says", "the King James puts it this way".
public enum VersionNameDetector {
    private static let table: [(String, String)] = [
        ("new king james", "NKJV"), ("nkjv", "NKJV"), ("n k j v", "NKJV"),
        ("king james", "KJV"), ("kjv", "KJV"), ("k j v", "KJV"), ("authorized version", "KJV"),
        ("new international version", "NIV"), ("new international", "NIV"), ("niv", "NIV"), ("n i v", "NIV"),
        ("english standard version", "ESV"), ("english standard", "ESV"), ("esv", "ESV"), ("e s v", "ESV"),
        ("new living translation", "NLT"), ("new living", "NLT"), ("nlt", "NLT"), ("n l t", "NLT"),
        ("new american standard", "NASB"), ("nasb", "NASB"), ("n a s b", "NASB"),
        ("american standard version", "ASV"), ("american standard", "ASV"), ("asv", "ASV"),
        ("world english bible", "WEB"), ("world english", "WEB"),
        ("youngs literal", "YLT"), ("young literal", "YLT"), ("ylt", "YLT"),
        ("berean standard", "BSB"), ("berean study bible", "BSB"), ("berean bible", "BSB"), ("bsb", "BSB"),
        ("new revised standard", "NRSV"), ("nrsv", "NRSV"),
        ("christian standard", "CSB"), ("csb", "CSB"), ("hcsb", "HCSB"),
        ("amplified bible", "AMP"), ("amplified version", "AMP"), ("the amplified", "AMP"),
        ("the message translation", "MSG"), ("the message version", "MSG"), ("the message bible", "MSG"),
        ("good news translation", "GNT"), ("good news bible", "GNT"),
        ("new century version", "NCV"), ("contemporary english version", "CEV"),
    ]

    private static let names: [(phrase: [String], abbreviation: String)] = table
        .map { (phrase: $0.0.split(separator: " ").map(String.init), abbreviation: $0.1) }
        .sorted { $0.phrase.count > $1.phrase.count }

    /// The last version named in `text`, as an abbreviation ("NIV").
    public static func detect(in text: String) -> String? {
        let tokens = TextNormalizer.tokens(text)
        var found: String?
        var i = 0
        while i < tokens.count {
            if let match = names.first(where: { name in
                i + name.phrase.count <= tokens.count && tokens[i..<(i + name.phrase.count)].elementsEqual(name.phrase)
            }) {
                found = match.abbreviation
                i += match.phrase.count
            } else {
                i += 1
            }
        }
        return found
    }
}
