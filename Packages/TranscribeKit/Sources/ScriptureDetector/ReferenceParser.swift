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
    /// Where the reference was said in the original text (UTF-16), if known.
    public var sourceRange: NSRange? = nil
    /// How it was said, which decides how the transcript is rewritten.
    public var form: Form = .absolute

    public enum Form: Sendable, Hashable {
        /// "John 3:16", "first Corinthians thirteen": replaced with the written reference.
        case absolute
        /// "verses 16 through 18" after John 3 was mentioned: replaced with the full reference.
        case contextVerse
        /// "the next verse": the words are kept and the reference added in brackets.
        case step
    }
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

    /// Finds references in `text`. With `context` (the passage the speaker is in), relative forms
    /// are understood too: "the next verse", "the previous verse", "verses 16 through 18".
    public static func parse(_ text: String, manual: Bool = false, context: BibleReference? = nil) -> [DetectedReference] {
        let tokens = SpokenReferenceNormalizer.normalize(text, manual: manual)
        var results: [DetectedReference] = []
        var context = context
        var i = 0
        while i < tokens.count {
            if let candidate = candidate(in: tokens, at: i) {
                let found = interpret(candidate, tokens: tokens, manual: manual)
                results += found
                if let last = found.last, last.confidence >= 0.75 { context = last.reference }
                i = candidate.last + 1
            } else if let context, let (reference, form, last) = relative(in: tokens, at: i, context: context) {
                results.append(DetectedReference(
                    reference: reference, alternatives: [], confidence: form == .step ? 0.85 : 0.8,
                    reasons: ["Follows on from \(context)."], phrase: phrase(tokens, i, last),
                    sourceRange: sourceRange(tokens, i, last), form: form
                ))
                i = last + 1
            } else {
                i += 1
            }
        }
        return results
    }

    /// Rewrites spoken references in a transcript line in their written form:
    ///   "John 316."                          -> "John 3:16."
    ///   "first Corinthians thirteen verse 4" -> "1 Corinthians 13:4"
    ///   "the next verse"                     -> "the next verse (John 3:17)"
    /// Only references at least `minimumConfidence` sure are rewritten, so "James 2 said" stays.
    public static func rewrite(_ text: String, references: [DetectedReference], minimumConfidence: Double = 0.75) -> String {
        let ns = text as NSString
        // Separate ranges said together ("verses 5 and 7") share one span.
        var groups: [(range: NSRange, refs: [DetectedReference])] = []
        for reference in references where reference.confidence >= minimumConfidence {
            guard let range = reference.sourceRange, range.location != NSNotFound, NSMaxRange(range) <= ns.length else { continue }
            if let index = groups.firstIndex(where: { $0.range == range }) { groups[index].refs.append(reference) }
            else if !groups.contains(where: { NSIntersectionRange($0.range, range).length > 0 }) { groups.append((range, [reference])) }
        }
        var result = text
        for group in groups.sorted(by: { $0.range.location > $1.range.location }) {
            let written = written(group.refs)
            var range = group.range
            let original = ns.substring(with: range)
            if group.refs[0].form == .step {
                result = (result as NSString).replacingCharacters(in: range, with: "\(original) (\(written))")
                continue
            }
            // "the third chapter of John" -> "John 3", not "the John 3".
            let firstWord = original.split(separator: " ").first.map { $0.lowercased() } ?? ""
            if leadingWords.contains(firstWord) || SpokenReferenceNormalizer.ordinalUnits[firstWord] != nil
                || SpokenReferenceNormalizer.tens[firstWord] != nil || SpokenReferenceNormalizer.ordinalTens[firstWord] != nil
                || SpokenReferenceNormalizer.ordinalTeens[firstWord] != nil,
               range.location >= 4, ns.substring(with: NSRange(location: range.location - 4, length: 4)).lowercased() == "the " {
                range = NSRange(location: range.location - 4, length: range.length + 4)
            }
            result = (result as NSString).replacingCharacters(in: range, with: written)
        }
        return result
    }

    private static let leadingWords: Set<String> = ["chapter", "verse", "verses"]

    /// "Proverbs 3:5, 7" for separate verses of one chapter; otherwise each reference in turn.
    static func written(_ refs: [DetectedReference]) -> String {
        let references = refs.map(\.reference)
        guard references.count > 1, let first = references.first,
              references.allSatisfy({ $0.book == first.book && $0.chapter == first.chapter && $0.verseStart != nil }) else {
            return references.map(\.description).joined(separator: "; ")
        }
        let rest = references.dropFirst().map { ref in
            ref.verseEnd == ref.verseStart ? "\(ref.verseStart!)" : "\(ref.verseStart!)-\(ref.verseEnd!)"
        }
        return ([first.description] + rest).joined(separator: ", ")
    }

    static func sourceRange(_ tokens: [Token], _ first: Int, _ last: Int) -> NSRange? {
        let ranges = tokens[first...last].map(\.range).filter { $0.location != NSNotFound }
        guard let start = ranges.map(\.location).min(), let end = ranges.map({ NSMaxRange($0) }).max() else { return nil }
        return NSRange(location: start, length: end - start)
    }

    static func phrase(_ tokens: [Token], _ first: Int, _ last: Int) -> String {
        tokens[first...last].map { token -> String in
            switch token.kind {
            case .word(let w): w
            case .number(let n, _): "\(n)"
            case .book(let b): b.key
            }
        }.joined(separator: " ")
    }

    // MARK: Relative references

    /// "next verse", "the following verse", "previous verse", "the verse before",
    /// "verse 17", "verses 16 through 18" — read against the passage being discussed.
    private static func relative(in tokens: [Token], at i: Int, context: BibleReference) -> (BibleReference, DetectedReference.Form, Int)? {
        let w = word(tokens, i)
        let next = word(tokens, i + 1)
        if (w == "next" || w == "following") && next == "verse" {
            return step(context, by: 1).map { ($0, .step, i + 1) }
        }
        if (w == "previous" || w == "preceding") && next == "verse" {
            return step(context, by: -1).map { ($0, .step, i + 1) }
        }
        if w == "verse", next == "before" {
            return step(context, by: -1).map { ($0, .step, i + 1) }
        }
        if w == "verse", next == "after", word(tokens, i + 2) == "that" {
            return step(context, by: 1).map { ($0, .step, i + 2) }
        }
        // "chapter 5 verse 3" without a book: the same book.
        if w == "chapter", let chapter = number(tokens, i + 1), let tail = verseTail(tokens, from: i + 2), tail.marked,
           tail.ranges.count == 1, !["of", "in"].contains(word(tokens, tail.last + 1) ?? "") {
            let range = tail.ranges[0]
            let reference = BibleReference(book: context.book, chapter: chapter, verseStart: range.lowerBound, verseEnd: range.upperBound)
            return reference.isValid ? (reference, .contextVerse, tail.last) : nil
        }
        // A bare "verse 17": not followed by "of John" (that is an absolute reference).
        if w == "verse" || w == "verses", i == 0 || tokens[i - 1].book == nil && tokens[i - 1].number == nil,
           let tail = verseTail(tokens, from: i), tail.ranges.count == 1, !tail.crossChapter,
           !["of", "in"].contains(word(tokens, tail.last + 1) ?? "") {
            let range = tail.ranges[0]
            let reference = BibleReference(book: context.book, chapter: context.chapter, verseStart: range.lowerBound, verseEnd: range.upperBound)
            guard reference.isValid else { return nil }
            return (reference, .contextVerse, tail.last)
        }
        return nil
    }

    /// The verse after (or before) a passage, crossing into the next or previous chapter.
    public static func step(_ reference: BibleReference, by delta: Int) -> BibleReference? {
        guard let start = reference.verseStart else { return nil }
        let end = reference.verseEnd ?? start
        if delta > 0 {
            let candidate = BibleReference(book: reference.book, chapter: reference.chapter, verseStart: end + 1)
            if candidate.isValid { return candidate }
            let nextChapter = BibleReference(book: reference.book, chapter: reference.chapter + 1, verseStart: 1)
            return nextChapter.isValid ? nextChapter : nil
        }
        if start > 1 { return BibleReference(book: reference.book, chapter: reference.chapter, verseStart: start - 1) }
        guard reference.chapter > 1 else { return nil }
        let count = Versification.verseCount(reference.book, chapter: reference.chapter - 1)
        return count > 0 ? BibleReference(book: reference.book, chapter: reference.chapter - 1, verseStart: count) : nil
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

        let phrase = phrase(tokens, c.first, c.last)
        let range = sourceRange(tokens, c.first, c.last)

        let others = options.dropFirst().compactMap(\.first)
        // Separate ranges ("verses four and six") become separate detections.
        return primary.enumerated().map { index, reference in
            DetectedReference(reference: reference, alternatives: index == 0 ? Array(others) : [], confidence: confidence, reasons: reasons, phrase: phrase, sourceRange: range)
        }
    }
}
