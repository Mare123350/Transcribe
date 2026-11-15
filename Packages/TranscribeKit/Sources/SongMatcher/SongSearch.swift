import Foundation
import TranscribeCore

/// What the operator can search a song by.
public struct SongSearchEntry: Sendable {
    public let id: UUID
    public let title: String
    public let author: String
    public let number: String
    /// Every lyric line, in order (the first one is the song's first line).
    public let lines: [String]
    public let isFavorite: Bool

    public init(id: UUID, title: String, author: String = "", number: String = "", lines: [String], isFavorite: Bool = false) {
        self.id = id
        self.title = title
        self.author = author
        self.number = number
        self.lines = lines
        self.isFavorite = isFavorite
    }

    public init(record: SongRecord, isFavorite: Bool = false) {
        self.init(id: record.id, title: record.title, author: record.artist, number: record.ccliNumber,
                  lines: record.sections.flatMap { $0.lyrics.components(separatedBy: .newlines) }.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                  isFavorite: isFavorite)
    }
}

public struct SongSearchResult: Sendable, Equatable {
    public enum Field: Sendable, Equatable { case title, firstLine, lyrics, author, number }
    public let id: UUID
    public let score: Double
    public let field: Field
    /// The lyric line that matched, to show under the title.
    public let matchedLine: String?
}

/// Finds songs as the operator types: by title, first line, any lyric line, author or number,
/// tolerating typos ("amazng grase") and unfinished words ("how gre").
public final class SongSearchIndex: Sendable {
    struct Indexed: Sendable {
        let entry: SongSearchEntry
        let title: [String]
        let author: [String]
        let lines: [[String]]
    }

    private let songs: [Indexed]

    public init(_ entries: [SongSearchEntry]) {
        songs = entries.map { entry in
            Indexed(entry: entry, title: TextNormalizer.tokens(entry.title), author: TextNormalizer.tokens(entry.author),
                    lines: entry.lines.map(TextNormalizer.tokens))
        }
    }

    public var count: Int { songs.count }

    public func search(_ query: String, limit: Int = 12) -> [SongSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        var tokens = TextNormalizer.tokens(trimmed)
        let content = tokens.filter { !TextNormalizer.stopwords.contains($0) }
        if !content.isEmpty && content.count < tokens.count && tokens.count > 2 { tokens = content }
        let digits = trimmed.filter(\.isNumber)
        let isNumber = digits.count >= 3 && digits.count == trimmed.filter { !$0.isWhitespace }.count

        var results: [SongSearchResult] = []
        for song in songs {
            var best: SongSearchResult?
            func consider(_ score: Double, _ field: SongSearchResult.Field, _ line: String? = nil) {
                guard score > 0 else { return }
                let boosted = score + (song.entry.isFavorite ? 0.02 : 0)
                if boosted > (best?.score ?? 0) { best = SongSearchResult(id: song.entry.id, score: boosted, field: field, matchedLine: line) }
            }
            if isNumber, !song.entry.number.isEmpty, song.entry.number.hasPrefix(digits) {
                consider(song.entry.number == digits ? 1.2 : 1.0, .number)
            }
            if !tokens.isEmpty {
                var title = Self.score(tokens, in: song.title)
                if title > 0, song.entry.title.lowercased().hasPrefix(trimmed.lowercased()) { title += 0.15 }
                consider(title * 1.0, .title)
                if let first = song.lines.first { consider(Self.score(tokens, in: first) * 0.9, .firstLine, song.entry.lines.first) }
                for (index, line) in song.lines.enumerated().dropFirst() {
                    consider(Self.score(tokens, in: line) * 0.8, .lyrics, song.entry.lines[index])
                }
                consider(Self.score(tokens, in: song.author) * 0.7, .author)
            }
            if let best, best.score >= 0.45 { results.append(best) }
        }
        return Array(results.sorted { ($0.score, $1.id.uuidString) > ($1.score, $0.id.uuidString) }.prefix(limit))
    }

    /// How well every query word appears among `field`'s words: 1 for all exact, less for
    /// prefixes and typos, 0 if any word is missing. Words in order score a little higher.
    static func score(_ query: [String], in field: [String]) -> Double {
        guard !query.isEmpty, !field.isEmpty else { return 0 }
        var total = 0.0
        var positions: [Int] = []
        for (index, word) in query.enumerated() {
            let isLast = index == query.count - 1
            var bestScore = 0.0
            var bestPosition = -1
            for (position, candidate) in field.enumerated() {
                let score = match(word, candidate, allowPrefix: isLast || word.count >= 4)
                if score > bestScore { bestScore = score; bestPosition = position }
                if bestScore == 1 { break }
            }
            guard bestScore > 0 else { return 0 }
            total += bestScore
            positions.append(bestPosition)
        }
        var score = total / Double(query.count)
        if positions.count > 1, positions == positions.sorted() { score += 0.05 }
        // A query covering most of a short field (a title) is a stronger match.
        score += 0.05 * min(1, Double(query.count) / Double(field.count))
        return min(score, 1.1)
    }

    static func match(_ word: String, _ candidate: String, allowPrefix: Bool) -> Double {
        if word == candidate { return 1 }
        if allowPrefix && word.count >= 2 && candidate.hasPrefix(word) { return 0.9 }
        guard word.count >= 4 else { return 0 }
        let limit = word.count >= 7 ? 2 : 1
        // Lengths too far apart can't be a typo of each other: skip the edit distance.
        if abs(word.count - candidate.count) <= limit, Similarity.levenshtein(word, candidate, limit: limit) <= limit { return 0.75 }
        // A typo in an unfinished word: compare with the same-length start of the candidate.
        if allowPrefix && candidate.count > word.count, candidate.first == word.first,
           Similarity.levenshtein(word, String(candidate.prefix(word.count)), limit: 1) <= 1 { return 0.65 }
        return 0
    }
}
