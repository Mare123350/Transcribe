import Foundation
import TranscribeCore

public struct SongMatch: Sendable, Equatable {
    public let songID: UUID
    public let title: String
    public let sectionIndex: Int
    public let sectionName: String
    /// 0…1: how much of what was just sung appears, in order, in this song.
    public let confidence: Double

    public init(songID: UUID, title: String, sectionIndex: Int, sectionName: String, confidence: Double) {
        self.songID = songID
        self.title = title
        self.sectionIndex = sectionIndex
        self.sectionName = sectionName
        self.confidence = confidence
    }
}

/// Matches recently sung words against the song library.
///
/// Sung transcription is messy: words are dropped, misheard, and repeated. Instead of exact text,
/// this compares overlapping word pairs and triples (n-grams) from a rolling window of the last
/// ~20 words with each song's lyrics. A window that mostly consists of a song's word pairs is
/// that song; ordinary speech shares single words with lyrics, but rarely runs of them.
public final class SongMatcher: Sendable {
    public static let windowSize = 20

    struct IndexedSection: Sendable {
        let song: Int
        let section: Int
        let unigrams: Set<String>
        let bigrams: Set<String>
        let trigrams: Set<String>
    }

    struct IndexedSong: Sendable {
        let record: SongRecord
        let unigrams: Set<String>
        let bigrams: Set<String>
        let trigrams: Set<String>
        let sections: [IndexedSection]
    }

    private let songs: [IndexedSong]
    /// Content word -> songs containing it, to skip songs that can't match.
    private let wordIndex: [String: [Int]]

    public init(songs records: [SongRecord]) {
        var songs: [IndexedSong] = []
        var wordIndex: [String: Set<Int>] = [:]
        for (songIndex, record) in records.enumerated() {
            let sections = record.sections.enumerated().map { sectionIndex, section in
                let tokens = TextNormalizer.tokens(section.lyrics)
                return IndexedSection(
                    song: songIndex, section: sectionIndex,
                    unigrams: Set(tokens),
                    bigrams: Set(Similarity.ngrams(tokens, n: 2)),
                    trigrams: Set(Similarity.ngrams(tokens, n: 3))
                )
            }
            // Song-wide sets also cover windows that straddle two sections.
            let allTokens = record.sections.flatMap { TextNormalizer.tokens($0.lyrics) }
            let song = IndexedSong(
                record: record,
                unigrams: Set(allTokens),
                bigrams: Set(Similarity.ngrams(allTokens, n: 2)),
                trigrams: Set(Similarity.ngrams(allTokens, n: 3)),
                sections: sections
            )
            songs.append(song)
            for word in song.unigrams where !TextNormalizer.stopwords.contains(word) {
                wordIndex[word, default: []].insert(songIndex)
            }
        }
        self.songs = songs
        self.wordIndex = wordIndex.mapValues { Array($0) }
    }

    public var isEmpty: Bool { songs.isEmpty }

    /// Best match for the last `windowSize` words of `text`.
    public func match(text: String) -> SongMatch? {
        match(window: Array(TextNormalizer.tokens(text).suffix(Self.windowSize)))
    }

    public func match(window: [String]) -> SongMatch? {
        guard window.count >= 6 else { return nil }
        let unigrams = Set(window)
        let bigrams = Set(Similarity.ngrams(window, n: 2))
        let trigrams = Set(Similarity.ngrams(window, n: 3))

        // Songs sharing at least three distinct content words with the window.
        var shared: [Int: Int] = [:]
        for word in unigrams where !TextNormalizer.stopwords.contains(word) {
            for song in wordIndex[word] ?? [] { shared[song, default: 0] += 1 }
        }

        var best: SongMatch?
        for (songIndex, count) in shared where count >= 3 {
            let song = songs[songIndex]
            let confidence = Self.score(unigrams, bigrams, trigrams, song.unigrams, song.bigrams, song.trigrams)
            guard confidence > (best?.confidence ?? 0) else { continue }
            let section = song.sections.max { a, b in
                Self.score(unigrams, bigrams, trigrams, a.unigrams, a.bigrams, a.trigrams)
                    < Self.score(unigrams, bigrams, trigrams, b.unigrams, b.bigrams, b.trigrams)
            }
            let sectionIndex = section?.section ?? 0
            best = SongMatch(
                songID: song.record.id,
                title: song.record.title,
                sectionIndex: sectionIndex,
                sectionName: song.record.sections.indices.contains(sectionIndex) ? song.record.sections[sectionIndex].name : "",
                confidence: confidence
            )
        }
        return best
    }

    /// Whether one transcribed segment, on its own, is part of the given song. Used to decide which
    /// lines to fold under a song block: "Amen, you may be seated" right after a hymn isn't.
    public func segmentBelongs(_ tokens: [String], to songID: UUID) -> Bool {
        guard let song = songs.first(where: { $0.record.id == songID }) else { return false }
        let content = tokens.filter { !TextNormalizer.stopwords.contains($0) }
        guard !content.isEmpty else { return false }
        if tokens.count >= 6 {
            let score = Self.score(Set(tokens), Set(Similarity.ngrams(tokens, n: 2)), Set(Similarity.ngrams(tokens, n: 3)), song.unigrams, song.bigrams, song.trigrams)
            return score >= 0.4
        }
        let known = content.filter { song.unigrams.contains($0) }.count
        return Double(known) / Double(content.count) >= 0.75
    }

    public func song(_ id: UUID) -> SongRecord? {
        songs.first { $0.record.id == id }?.record
    }

    /// Weighted containment of the window's n-grams in the lyrics. Word pairs and triples carry most
    /// of the weight because single words are shared with ordinary speech.
    static func score(_ u: Set<String>, _ b: Set<String>, _ t: Set<String>, _ su: Set<String>, _ sb: Set<String>, _ st: Set<String>) -> Double {
        0.2 * Similarity.containment(u, in: su) + 0.45 * Similarity.containment(b, in: sb) + 0.35 * Similarity.containment(t, in: st)
    }
}
