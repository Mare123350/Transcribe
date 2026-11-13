import Foundation

/// A Bible reference heard in speech.
public struct DetectedReference: Sendable, Hashable {
    public let reference: BibleReference
    /// Other plausible readings, e.g. 2 Corinthians when only "Corinthians" was heard.
    public let alternatives: [BibleReference]
    /// 0…1. Below 0.75 the operator should confirm it.
    public let confidence: Double
    public let reasons: [String]
    /// The words that made up the reference, as normalized tokens.
    public let phrase: String
}

/// Step 2: finds references in normalized tokens and checks they exist.
///   "turn to first Corinthians chapter thirteen verse four" -> 1 Corinthians 13:4
///   "John 3:16"                                              -> John 3:16
///   "Psalm one nineteen verse one oh five"                   -> Psalm 119:105
public enum ReferenceParser {
    typealias Token = SpokenReferenceNormalizer.Token

    /// Words after a number that show it's a count, not a chapter: "John three times".
    static let countingWords: Set<String> = ["times", "time", "of", "people", "men", "women", "days", "day", "years", "year", "months", "weeks", "hours", "minutes", "disciples", "more", "or", "children", "sons", "daughters", "things", "ways", "points", "others", "friends", "brothers", "sisters", "loaves", "fish", "percent", "dollars", "miles", "oclock", "am", "pm", "who", "were", "are"]
    /// Words before a name that show it's a person: "Pastor John three weeks ago".
    static let titleWords: Set<String> = ["pastor", "brother", "sister", "pope", "king", "bishop", "father", "elder", "deacon", "mr", "mrs", "ms", "dr", "doctor", "reverend", "uncle", "aunt", "my", "named", "called"]
    static let fillers: Set<String> = ["and", "at", "in", "from"]

    struct Candidate {
        let book: BookMatch
        var chapter: Int?
        var ranges: [ClosedRange<Int>]
        var compound: [Int]?
        var chapterWord: Bool
        var marked: Bool
        var crossChapter = false
        var numberBreak = false
        let first: Int
        var last: Int
    }

    public static func parse(_ text: String, manual: Bool = false) -> [DetectedReference] {
        let tokens = SpokenReferenceNormalizer.normalize(text, manual: manual)
        var results: [DetectedReference] = []
        var i = 0
        while i < tokens.count {
            if let candidate = candidate(in: tokens, at: i) {
                results += interpret(candidate, tokens: tokens, manual: manual)
                i = candidate.last + 1
            } else {
                i += 1
            }
        }
        return results
    }

    /// One reference typed by the operator: "1 cor 13:4-7", "first corinthians thirteen".
    public static func parseManual(_ text: String) -> DetectedReference? {
        parse(text, manual: true).first
    }

    // MARK: Matching

    private static func word(_ tokens: [Token], _ i: Int) -> String? { i < tokens.count ? tokens[i].word : nil }
    private static func number(_ tokens: [Token], _ i: Int) -> Int? { i < tokens.count ? tokens[i].number : nil }

    private static func candidate(in tokens: [Token], at i: Int) -> Candidate? {
        // verse N [to|and M] of|in BOOK [chapter] C
        if ["verse", "verses"].contains(word(tokens, i) ?? ""), let start = number(tokens, i + 1) {
            var j = i + 2
            var end = start
            if ["to", "and"].contains(word(tokens, j) ?? ""), let value = number(tokens, j + 1) { end = value; j += 2 }
            if ["of", "in"].contains(word(tokens, j) ?? ""), j + 1 < tokens.count, let book = tokens[j + 1].book {
                var k = j + 2
                if word(tokens, k) == "chapter" { k += 1 }
                if let chapter = number(tokens, k) {
                    return Candidate(book: book, chapter: chapter, ranges: [start...max(start, end)], chapterWord: true, marked: true, first: i, last: k)
                }
            }
        }

        // chapter N of BOOK [verses…]
        if word(tokens, i) == "chapter", let chapter = number(tokens, i + 1), word(tokens, i + 2) == "of" {
            var j = i + 3
            if word(tokens, j) == "the" { j += 1 }
            if j < tokens.count, let book = tokens[j].book {
                var candidate = Candidate(book: book, chapter: chapter, ranges: [], chapterWord: true, marked: false, first: i, last: j)
                if let tail = verseTail(tokens, from: j + 1) {
                    candidate.ranges = tail.ranges
                    candidate.marked = tail.marked
                    candidate.crossChapter = tail.crossChapter
                    candidate.last = tail.last
                }
                return candidate
            }
        }

        guard let book = tokens[i].book else { return nil }

        // BOOK [the] [chapter|number] N [verses…]
        var j = i + 1
        var chapterWord = false
        if word(tokens, j) == "the", word(tokens, j + 1) == "chapter" { j += 2; chapterWord = true }
        else if word(tokens, j) == "chapter" || word(tokens, j) == "number" { j += 1; chapterWord = true }
        if j < tokens.count, case .number(var chapter, let compound) = tokens[j].kind {
            var candidate = Candidate(book: book, chapter: chapter, ranges: [], compound: compound, chapterWord: chapterWord, marked: false, numberBreak: tokens[j].breakBefore, first: i, last: j)
            var tail = verseTail(tokens, from: j + 1)

            // "Psalm one nineteen" means Psalm 119 (Psalm 1 has only six verses).
            if book.ids.first == "PSA", chapter == 1, let t = tail, !t.marked, let first = t.ranges.first?.lowerBound, (10...50).contains(first) {
                chapter = 100 + first
                candidate.chapter = chapter
                candidate.last = j + 1
                tail = verseTail(tokens, from: j + 2)
            }
            if let tail {
                candidate.ranges = tail.ranges
                candidate.marked = tail.marked
                candidate.crossChapter = tail.crossChapter
                candidate.last = tail.last
                candidate.compound = nil
            } else if let split = splitRunTogether(chapter, book: book) {
                // The transcriber sometimes drops the colon: "John 316" is John 3:16.
                candidate.chapter = split.chapter
                candidate.ranges = [split.verse...split.verse]
                candidate.marked = true
                candidate.compound = nil
                if word(tokens, j + 1) == "to", let end = number(tokens, j + 2), end > split.verse {
                    candidate.ranges = [split.verse...end]
                    candidate.last = j + 2
                }
            }
            return candidate
        }

        // BOOK verse N — one-chapter books: "Jude verse three"
        if ["verse", "verses"].contains(word(tokens, i + 1) ?? ""), let tail = verseTail(tokens, from: i + 1) {
            return Candidate(book: book, chapter: nil, ranges: tail.ranges, chapterWord: false, marked: true, first: i, last: tail.last)
        }
        return nil
    }

    /// "316" after John: not a chapter, but split as 3:16 it is. Only used when the whole number
    /// isn't a valid chapter (Psalm 119 stays Psalm 119) and exactly one split exists.
    private static func splitRunTogether(_ value: Int, book: BookMatch) -> (chapter: Int, verse: Int)? {
        guard value >= 100, book.ids.count == 1, let id = book.ids.first else { return nil }
        guard BibleReference(book: id, chapter: value).isValid == false else { return nil }
        let digits = String(value)
        let splits = (1..<digits.count).compactMap { index -> (Int, Int)? in
            let chapterDigits = digits.prefix(index), verseDigits = digits.dropFirst(index)
            guard verseDigits.first != "0", let chapter = Int(chapterDigits), let verse = Int(verseDigits) else { return nil }
            return BibleReference(book: id, chapter: chapter, verseStart: verse).isValid ? (chapter, verse) : nil
        }
        return splits.count == 1 ? splits[0] : nil
    }

    /// Reads verses after a chapter: "16", "verse 16", "verses 4 to 7", "verses 1, 3 and 5".
    private static func verseTail(_ tokens: [Token], from start: Int) -> (ranges: [ClosedRange<Int>], marked: Bool, crossChapter: Bool, last: Int)? {
        var j = start
        var marked = false
        var plural = false
        var k = j
        if let w = word(tokens, k), fillers.contains(w) { k += 1 }
        else if let w = word(tokens, k), ["beginning", "starting"].contains(w), ["at", "with", "in", "from"].contains(word(tokens, k + 1) ?? "") { k += 2 }
        if let w = word(tokens, k), w == "verse" || w == "verses" {
            marked = true
            plural = w == "verses"
            j = k + 1
        }
        guard let first = number(tokens, j) else { return nil }
        var ranges = [first...first]
        var last = j
        var crossChapter = false
        var p = j + 1
        while p < tokens.count {
            var q = p
            var joiner: String?
            if let w = word(tokens, q), w == "to" || w == "and" { joiner = w; q += 1 }
            if let w = word(tokens, q), w == "verse" || w == "verses" { q += 1 }
            guard let value = number(tokens, q) else { break }
            let current = ranges[ranges.count - 1]
            if joiner == "to" {
                if value <= current.upperBound { crossChapter = true; break }
                ranges[ranges.count - 1] = current.lowerBound...value
            } else if value == current.upperBound + 1 {
                ranges[ranges.count - 1] = current.lowerBound...value
            } else if plural && value > current.upperBound {
                ranges.append(value...value)
            } else {
                break
            }
            last = q
            p = q + 1
        }
        return (ranges, marked, crossChapter, last)
    }

    // MARK: Interpretation

    private static func readings(for id: String, _ c: Candidate) -> [[BibleReference]] {
        func refs(_ chapter: Int, _ ranges: [ClosedRange<Int>]) -> [BibleReference] {
            ranges.isEmpty ? [BibleReference(book: id, chapter: chapter)]
                : ranges.map { BibleReference(book: id, chapter: chapter, verseStart: $0.lowerBound, verseEnd: $0.upperBound) }
        }
        if Books.singleChapterBooks.contains(id) {
            // "Jude three" is verse 3; "Jude one twenty" is 1:20; "Jude one" is the whole book.
            guard let chapter = c.chapter else { return [refs(1, c.ranges)] }
            if !c.ranges.isEmpty { return [refs(chapter, c.ranges)] }
            return chapter == 1 ? [[BibleReference(book: id, chapter: 1)]] : [[BibleReference(book: id, chapter: 1, verseStart: chapter)]]
        }
        guard let chapter = c.chapter else { return [] }
        var result = [refs(chapter, c.ranges)]
        if let compound = c.compound, compound.count == 2 {
            result.append([BibleReference(book: id, chapter: compound[0], verseStart: compound[1])]) // "twenty three" -> 20:3
        }
        return result
    }

    private static func interpret(_ c: Candidate, tokens: [Token], manual: Bool) -> [DetectedReference] {
        let book = c.book
        let chapterOnly = c.ranges.isEmpty
        let isNamelike = !book.numbered && book.ids.contains { Books.book($0)?.isCommonWord == true }
        let unprompted = chapterOnly && !c.chapterWord && !book.cued

        if !manual && unprompted && (isNamelike || book.bare || book.misheard) {
            if let next = word(tokens, c.last + 1), countingWords.contains(next) { return [] }
            if c.first > 0, let previous = word(tokens, c.first - 1), titleWords.contains(previous) { return [] }
            if c.numberBreak { return [] }
        }

        var options: [[BibleReference]] = []
        var usedFallback = false
        for id in book.ids {
            for (index, refs) in readings(for: id, c).enumerated() where refs.allSatisfy(\.isValid) {
                if index > 0 && options.isEmpty { usedFallback = true }
                options.append(refs)
            }
        }
        guard let primary = options.first else { return [] }

        var reasons: [String] = []
        var confidence = 0.95
        if !manual {
            if book.bare {
                reasons.append("The book's number wasn't heard (“\(book.heard)”).")
                confidence = min(confidence, 0.6)
            }
            if book.misheard || book.fuzzy {
                reasons.append("Heard “\(book.heard)”, which may be a transcription error.")
                confidence = min(confidence, 0.7)
            }
            if usedFallback {
                reasons.append("Read as chapter and verse because that chapter doesn't exist.")
                confidence = min(confidence, 0.7)
            }
            if c.crossChapter {
                reasons.append("The passage may continue into another chapter.")
                confidence = min(confidence, 0.8)
            }
            if isNamelike && unprompted && !usedFallback {
                reasons.append("“\(book.heard)” followed by one number could be ordinary speech.")
                confidence = min(confidence, 0.55)
            }
        }

        let phrase = tokens[c.first...c.last].map { token -> String in
            switch token.kind {
            case .word(let w): w
            case .number(let n, _): "\(n)"
            case .book(let b): b.key
            }
        }.joined(separator: " ")

        let others = options.dropFirst().compactMap(\.first)
        // Separate ranges ("verses four and six") become separate detections.
        return primary.enumerated().map { index, reference in
            DetectedReference(reference: reference, alternatives: index == 0 ? Array(others) : [], confidence: confidence, reasons: reasons, phrase: phrase)
        }
    }
}
