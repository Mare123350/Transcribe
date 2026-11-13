import Foundation

/// A passage: a whole chapter, one verse, or a verse range within a chapter.
public struct BibleReference: Sendable, Hashable, Codable, CustomStringConvertible {
    public let book: String
    public let chapter: Int
    public let verseStart: Int?
    public let verseEnd: Int?

    public init(book: String, chapter: Int, verseStart: Int? = nil, verseEnd: Int? = nil) {
        self.book = book
        self.chapter = chapter
        self.verseStart = verseStart
        self.verseEnd = verseStart == nil ? nil : max(verseEnd ?? verseStart!, verseStart!)
    }

    public var isWholeChapter: Bool { verseStart == nil }

    /// "John 3:16", "1 Corinthians 13:4-7", "Psalm 23", "Jude 3".
    public var description: String {
        let single = Books.singleChapterBooks.contains(book)
        let name = Books.displayName(book, withChapter: !(single && isWholeChapter))
        guard let start = verseStart else { return single ? Books.displayName(book, withChapter: false) : "\(name) \(chapter)" }
        let verses = verseEnd.map { $0 == start ? "\(start)" : "\(start)-\($0)" } ?? "\(start)"
        return single ? "\(name) \(verses)" : "\(name) \(chapter):\(verses)"
    }

    /// Stable key, e.g. "JHN.3.16-16" or "PSA.23".
    public var key: String {
        guard let start = verseStart else { return "\(book).\(chapter)" }
        return "\(book).\(chapter).\(start)-\(verseEnd ?? start)"
    }

    /// The verses this passage covers, using the canonical versification.
    public var verseNumbers: ClosedRange<Int> {
        if let start = verseStart { return start...(verseEnd ?? start) }
        return 1...max(1, Versification.verseCount(book, chapter: chapter))
    }

    public var isValid: Bool {
        let verses = Versification.verseCount(book, chapter: chapter)
        guard verses > 0 else { return false }
        guard let start = verseStart else { return true }
        return start >= 1 && (verseEnd ?? start) <= verses
    }
}
