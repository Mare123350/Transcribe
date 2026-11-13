import Foundation
import TranscribeCore

/// An inverted index from distinctive word 4-grams to the verses that contain them, across every
/// loaded translation. Used to recognize verses quoted without a reference.
///
/// Each entry packs a 40-bit n-gram hash and a 24-bit verse key into one UInt64, so the whole index
/// is one sorted array (about 25 MB for five translations) searched by binary search.
public final class QuoteIndex: Sendable {
    public static let n = 4
    private let entries: [UInt64]

    /// - Parameter maxVersesPerGram: n-grams found in more verses than this ("and it came to pass")
    ///   are dropped as not distinctive.
    public init(translations: [BibleTranslation], maxVersesPerGram: Int = 24) {
        var raw: [UInt64] = []
        raw.reserveCapacity(translations.count * 800_000)
        for translation in translations {
            translation.forEachVerse { verse in
                guard let key = Self.verseKey(book: verse.book, chapter: verse.chapter, verse: verse.verse) else { return }
                let tokens = TextNormalizer.tokens(verse.text)
                Self.forEachGram(tokens) { hash in raw.append(hash << 24 | UInt64(key)) }
            }
        }
        raw.sort()

        // Remove duplicates (the same n-gram in several translations) and over-common n-grams.
        var kept: [UInt64] = []
        kept.reserveCapacity(raw.count / 2)
        var start = 0
        while start < raw.count {
            let gram = raw[start] >> 24
            var end = start
            var run: [UInt64] = []
            while end < raw.count && raw[end] >> 24 == gram {
                if run.last != raw[end] { run.append(raw[end]) }
                end += 1
            }
            if run.count <= maxVersesPerGram { kept += run }
            start = end
        }
        entries = kept
    }

    init(entries: [UInt64]) {
        self.entries = entries
    }

    public var count: Int { entries.count }

    // MARK: Disk cache

    /// Bumped when the index format or tokenizer changes, so old caches are ignored.
    static let formatVersion = 1

    /// A name that changes whenever the translations (or their files) change.
    static func cacheName(for translations: [BibleTranslation]) -> String {
        var parts = ["v\(formatVersion)"]
        for translation in translations.sorted(by: { $0.info.id < $1.info.id }) {
            let attributes = try? FileManager.default.attributesOfItem(atPath: translation.url.path)
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            parts.append("\(translation.info.id):\(size):\(Int(modified))")
        }
        return String(format: "quote-index-%016llx.bin", Similarity.hash(words: parts[...]))
    }

    /// Loads the index from `directory` if it was built for these translations; otherwise builds
    /// it and saves it there. Building takes seconds; loading takes milliseconds.
    public static func loadOrBuild(translations: [BibleTranslation], cacheDirectory: URL?) -> QuoteIndex {
        guard let cacheDirectory else { return QuoteIndex(translations: translations) }
        let url = cacheDirectory.appendingPathComponent(cacheName(for: translations))
        if let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count % 8 == 0, !data.isEmpty {
            let entries = data.withUnsafeBytes { Array($0.bindMemory(to: UInt64.self)) }
            return QuoteIndex(entries: entries)
        }
        let index = QuoteIndex(translations: translations)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        // Old caches for other translation sets are no longer needed.
        for old in (try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)) ?? []
        where old.lastPathComponent.hasPrefix("quote-index-") {
            try? FileManager.default.removeItem(at: old)
        }
        let data = index.entries.withUnsafeBytes { Data($0) }
        try? data.write(to: url, options: .atomic)
        return index
    }

    /// Verses sharing at least `minimumHits` distinct n-grams with `tokens`, most hits first.
    public func candidates(for tokens: [String], minimumHits: Int = 3, limit: Int = 5) -> [(reference: BibleReference, hits: Int)] {
        var hits: [UInt32: Int] = [:]
        var seenGrams = Set<UInt64>()
        Self.forEachGram(tokens) { hash in
            guard seenGrams.insert(hash).inserted else { return }
            for key in lookup(hash) { hits[key, default: 0] += 1 }
        }
        return hits.filter { $0.value >= minimumHits }
            .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .prefix(limit)
            .compactMap { key, count in Self.reference(for: key).map { ($0, count) } }
    }

    private func lookup(_ hash: UInt64) -> [UInt32] {
        let target = hash << 24
        var low = 0, high = entries.count
        while low < high {
            let mid = (low + high) / 2
            if entries[mid] < target { low = mid + 1 } else { high = mid }
        }
        var result: [UInt32] = []
        while low < entries.count && entries[low] >> 24 == hash {
            result.append(UInt32(entries[low] & 0xFF_FFFF))
            low += 1
        }
        return result
    }

    /// Calls `body` with the 40-bit hash of every n-gram that has at least one non-stopword.
    static func forEachGram(_ tokens: [String], _ body: (UInt64) -> Void) {
        guard tokens.count >= n else { return }
        for start in 0...(tokens.count - n) {
            let gram = tokens[start..<(start + n)]
            guard gram.contains(where: { !TextNormalizer.stopwords.contains($0) }) else { continue }
            body(Similarity.hash(words: gram) & 0xFF_FFFF_FFFF)
        }
    }

    private static let bookIndex: [String: Int] = Dictionary(uniqueKeysWithValues: Books.canonicalOrder.enumerated().map { ($1, $0) })

    static func verseKey(book: String, chapter: Int, verse: Int) -> UInt32? {
        guard let index = bookIndex[book], chapter < 256, verse < 256 else { return nil }
        return UInt32(index) << 16 | UInt32(chapter) << 8 | UInt32(verse)
    }

    static func reference(for key: UInt32) -> BibleReference? {
        let index = Int(key >> 16), chapter = Int(key >> 8 & 0xFF), verse = Int(key & 0xFF)
        guard index < Books.canonicalOrder.count else { return nil }
        return BibleReference(book: Books.canonicalOrder[index], chapter: chapter, verseStart: verse)
    }
}
