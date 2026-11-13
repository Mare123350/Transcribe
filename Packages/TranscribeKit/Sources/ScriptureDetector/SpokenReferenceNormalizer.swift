import Foundation
import TranscribeCore

/// A book name recognized in speech, with how it was heard.
public struct BookMatch: Sendable, Hashable {
    public let key: String
    /// Usually one book. Several when the number was missing ("Corinthians" -> 1CO or 2CO).
    public let ids: [String]
    public var numbered = false
    public var bare = false
    /// Introduced by a cue like "the book of" or "the gospel of".
    public var cued = false
    public var heard = ""
    public var fuzzy = false
    public var misheard = false
}

/// Step 1 of reference detection: rewrite a transcript into tokens a simple parser can read.
///   "First Corinthians thirteen, verses four to seven" -> [book 1CO] [13] verses [4] to [7]
///   "John 3:16-18"                                     -> [book JHN] [3] verse [16] to [18]
public enum SpokenReferenceNormalizer {
    public struct Token: Sendable, Hashable {
        public enum Kind: Sendable, Hashable {
            case word(String)
            case number(Int, compound: [Int]?)
            case book(BookMatch)
        }
        public let kind: Kind
        /// A sentence boundary (. ? !) came right before this token.
        public var breakBefore: Bool

        var word: String? { if case .word(let w) = kind { w } else { nil } }
        var number: Int? { if case .number(let n, _) = kind { n } else { nil } }
        var book: BookMatch? { if case .book(let b) = kind { b } else { nil } }
    }

    struct Raw {
        let text: String
        let breakBefore: Bool
    }

    // MARK: Vocabulary

    static let units = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9]
    static let teens = ["ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19]
    static let tens = ["twenty": 20, "thirty": 30, "forty": 40, "fourty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90]
    static let ordinalUnits = ["first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9]
    static let ordinalTeens = ["tenth": 10, "eleventh": 11, "twelfth": 12, "thirteenth": 13, "fourteenth": 14, "fifteenth": 15, "sixteenth": 16, "seventeenth": 17, "eighteenth": 18, "nineteenth": 19]
    static let ordinalTens = ["twentieth": 20, "thirtieth": 30, "fortieth": 40, "fiftieth": 50, "sixtieth": 60, "seventieth": 70, "eightieth": 80, "ninetieth": 90]
    /// Read as numbers only right after a book, number, "chapter" or "verse". "for" is deliberately
    /// absent: "John three for God so loved" must not become John 3:4.
    static let homophones = ["won": 1, "ate": 8, "fore": 4]
    static let bookPrefixes = ["first": 1, "1st": 1, "1": 1, "one": 1, "i": 1, "second": 2, "2nd": 2, "2": 2, "two": 2, "too": 2, "ii": 2, "third": 3, "3rd": 3, "3": 3, "three": 3, "iii": 3]
    static let cues: [[String]] = [
        "book of the prophet", "the book of the prophet", "the book of", "book of",
        "the gospel according to saint", "the gospel according to", "gospel according to saint", "gospel according to",
        "the gospel of saint", "the gospel of", "gospel of saint", "gospel of",
        "letter to the", "letter of", "letter to", "epistle to the", "epistle of", "epistle to", "general epistle of",
        "saint", "st", "prophet",
    ].map { $0.split(separator: " ").map(String.init) }.sorted { $0.count > $1.count }
    static let keywords = ["verse": "verse", "verses": "verses", "versus": "verses", "vs": "verse", "vv": "verses", "chapter": "chapter", "chapters": "chapter", "chap": "chapter"]
    static let rangeWords: Set<String> = ["through", "thru", "till", "until", "too", "to"]

    enum AliasEntry {
        case book(key: String, id: String, misheard: Bool)
        case numbered(Books.NumberedBase)
    }

    static let (liveAliases, writtenAliases): ([String: AliasEntry], [String: AliasEntry]) = {
        var live: [String: AliasEntry] = [:]
        var written: [String: AliasEntry] = [:]
        for base in Books.numberedBases {
            live[base.key] = live[base.key] ?? .numbered(base)
            for alias in base.aliases { live[alias] = live[alias] ?? .numbered(base) }
            for alias in base.abbreviations { written[alias] = written[alias] ?? .numbered(base) }
        }
        for book in Books.all where !book.id.first!.isNumber && book.id != "JHN" {
            let key = (book.singular ?? book.name).lowercased()
            let entry = AliasEntry.book(key: key, id: book.id, misheard: false)
            for name in [key, book.name.lowercased()] + book.aliases where live[name] == nil { live[name] = entry }
            for name in book.misheard where live[name] == nil { live[name] = .book(key: key, id: book.id, misheard: true) }
            for name in book.abbreviations where written[name] == nil { written[name] = entry }
        }
        return (live, written)
    }()

    static let maxAliasWords = 5

    /// Long, distinctive names only: fuzzy matching short names would fire on ordinary speech.
    static let fuzzyTargets: [String] = liveAliases.compactMap { phrase, entry in
        guard phrase.count >= 7, !phrase.contains(" ") else { return nil }
        switch entry {
        case .book(_, let id, let misheard):
            return misheard || Books.book(id)?.isCommonWord == true ? nil : phrase
        case .numbered(let base):
            return base.defaultID == nil ? phrase : nil
        }
    }.sorted()

    // MARK: Tokenizing

    private static let tokenPattern = try! NSRegularExpression(pattern: #"\d+(?:st|nd|rd|th)?(?:[:.\-–—]\d+)*|\p{L}+(?:['’\-–]\p{L}+)*"#)

    static func tokenize(_ raw: String) -> [Raw] {
        let ns = raw as NSString
        var result: [Raw] = []
        var previousEnd = 0
        for match in tokenPattern.matches(in: raw, range: NSRange(location: 0, length: ns.length)) {
            let between = ns.substring(with: NSRange(location: previousEnd, length: match.range.location - previousEnd))
            let breakBefore = between.contains { ".?!".contains($0) }
            previousEnd = match.range.location + match.range.length
            var text = ns.substring(with: match.range).lowercased()
            if text.hasSuffix("'s") || text.hasSuffix("’s") { text = String(text.dropLast(2)) }
            text.removeAll { $0 == "'" || $0 == "’" }

            if text.first?.isNumber == true, text.contains(where: { ":.-–—".contains($0) }) {
                // "13:4-7" -> 13 verse 4 to 7
                var first = true
                var current = ""
                for character in text {
                    if character.isNumber {
                        current.append(character)
                    } else {
                        if !current.isEmpty { result.append(Raw(text: current, breakBefore: first && breakBefore)); first = false }
                        current = ""
                        result.append(Raw(text: ":.".contains(character) ? "verse" : "to", breakBefore: false))
                    }
                }
                if !current.isEmpty { result.append(Raw(text: current, breakBefore: first && breakBefore)) }
            } else if text.contains(where: { "-–".contains($0) }) {
                let parts = text.split(whereSeparator: { "-–".contains($0) }).map(String.init)
                for (i, part) in parts.enumerated() { result.append(Raw(text: part, breakBefore: i == 0 && breakBefore)) }
            } else {
                result.append(Raw(text: text, breakBefore: breakBefore))
            }
        }
        return result
    }

    // MARK: Books

    private static func matches(_ src: [Raw], _ i: Int, _ words: [String]) -> Bool {
        guard i + words.count <= src.count else { return false }
        return words.indices.allSatisfy { src[i + $0].text == words[$0] }
    }

    private static func longestAlias(_ src: [Raw], _ i: Int, manual: Bool) -> (AliasEntry, Int)? {
        for length in stride(from: maxAliasWords, through: 1, by: -1) where i + length <= src.count {
            let phrase = src[i..<(i + length)].map(\.text).joined(separator: " ")
            if manual, let entry = writtenAliases[phrase] { return (entry, length) }
            if let entry = liveAliases[phrase] { return (entry, length) }
        }
        return nil
    }

    private static func looksNumeric(_ raw: Raw?) -> Bool {
        guard let text = raw?.text else { return false }
        return text.first?.isNumber == true || units[text] != nil || teens[text] != nil || tens[text] != nil || text == "chapter" || text == "hundred"
    }

    private static func fuzzyAlias(_ src: [Raw], _ i: Int) -> (AliasEntry, Int)? {
        let word = src[i].text
        guard word.count >= 7, i + 1 < src.count, looksNumeric(src[i + 1]) else { return nil }
        let limit = word.count >= 9 ? 2 : 1
        guard let target = fuzzyTargets.first(where: { Similarity.levenshtein(word, $0, limit: limit) <= limit }) else { return nil }
        return liveAliases[target].map { ($0, 1) }
    }

    static func matchBook(_ src: [Raw], _ i: Int, manual: Bool, allowPrefix: Bool) -> (end: Int, book: BookMatch)? {
        var j = i
        var number: Int?
        if allowPrefix, let prefix = bookPrefixes[src[i].text] {
            number = prefix
            j += 1
        }
        var cued = false
        if let cue = cues.first(where: { matches(src, j, $0) }) {
            j += cue.count
            cued = true
        }
        guard j < src.count else { return nil }

        var fuzzy = false
        var found = longestAlias(src, j, manual: manual)
        if found == nil, let match = fuzzyAlias(src, j) {
            found = match
            fuzzy = true
        }
        guard let (entry, length) = found else { return nil }
        let heard = src[j..<(j + length)].map(\.text).joined(separator: " ")
        let end = j + length

        switch entry {
        case .numbered(let base):
            if let number {
                guard let id = base.ids[number] else { return nil }
                return (end, BookMatch(key: "\(number) \(base.key)", ids: [id], numbered: true, cued: cued, heard: heard, fuzzy: fuzzy))
            }
            if let defaultID = base.defaultID {
                return (end, BookMatch(key: base.key, ids: [defaultID], cued: cued, heard: heard, fuzzy: fuzzy))
            }
            return (end, BookMatch(key: base.key, ids: base.ids.keys.sorted().compactMap { base.ids[$0] }, bare: true, cued: cued, heard: heard, fuzzy: fuzzy))
        case .book(let key, let id, let misheard):
            // "second Romans" isn't a book; let the number fall through as a plain word.
            if number != nil { return nil }
            return (end, BookMatch(key: key, ids: [id], cued: cued, heard: heard, fuzzy: fuzzy, misheard: misheard))
        }
    }

    // MARK: Numbers

    private static func parseNumber(_ src: [Raw], _ i: Int, manual: Bool) -> (value: Int, length: Int, compound: [Int]?)? {
        guard i < src.count else { return nil }
        let text = src[i].text
        if let value = Int(text) { return (value, 1, nil) }
        if let value = suffixedNumber(text) { return (value, 1, nil) }

        // "one hundred and nineteen", "a hundred three", "hundred"
        let hundredAt: Int? = text == "hundred" ? i
            : (i + 1 < src.count && src[i + 1].text == "hundred" && (text == "a" || units[text] != nil) ? i + 1 : nil)
        if let hundredAt {
            let multiplier = units[text] ?? 1
            var j = hundredAt + 1
            if j < src.count && src[j].text == "and" { j += 1 }
            if let rest = parseTensAndUnits(src, j, manual: manual) {
                return (multiplier * 100 + rest.value, j + rest.length - i, nil)
            }
            return (multiplier * 100, hundredAt + 1 - i, nil)
        }

        // "one oh five" -> 105
        if text == "one", i + 2 < src.count, ["oh", "o", "zero"].contains(src[i + 1].text), let unit = units[src[i + 2].text] {
            return (100 + unit, 3, nil)
        }
        return parseTensAndUnits(src, i, manual: manual)
    }

    private static func parseTensAndUnits(_ src: [Raw], _ i: Int, manual: Bool) -> (value: Int, length: Int, compound: [Int]?)? {
        guard i < src.count else { return nil }
        let text = src[i].text
        if let ten = tens[text] {
            // "twenty two Timothy" is 20, then 2 Timothy.
            if i + 1 < src.count, let unit = units[src[i + 1].text],
               matchBook(src, i + 1, manual: manual, allowPrefix: true)?.book.numbered != true {
                return (ten + unit, 2, [ten, unit])
            }
            return (ten, 1, nil)
        }
        if let teen = teens[text] { return (teen, 1, nil) }
        if let unit = units[text] { return (unit, 1, nil) }
        return nil
    }

    private static func suffixedNumber(_ text: String) -> Int? {
        for suffix in ["st", "nd", "rd", "th"] where text.hasSuffix(suffix) {
            if let value = Int(text.dropLast(2)) { return value }
        }
        return nil
    }

    /// "twenty third", "hundred and nineteenth", "sixteenth", "23rd"
    private static func parseOrdinal(_ src: [Raw], _ i: Int) -> (value: Int, length: Int)? {
        guard i < src.count else { return nil }
        let text = src[i].text
        if let value = suffixedNumber(text) { return (value, 1) }
        func small(_ at: Int) -> (Int, Int)? {
            guard at < src.count else { return nil }
            let word = src[at].text
            if let v = ordinalUnits[word] ?? ordinalTeens[word] ?? ordinalTens[word] { return (v, 1) }
            if let ten = tens[word], at + 1 < src.count, let unit = ordinalUnits[src[at + 1].text] { return (ten + unit, 2) }
            return nil
        }
        let hundredAt: Int? = text == "hundred" ? i
            : (i + 1 < src.count && src[i + 1].text == "hundred" && (text == "one" || text == "a") ? i + 1 : nil)
        if let hundredAt {
            var j = hundredAt + 1
            if j < src.count && src[j].text == "and" { j += 1 }
            guard let rest = small(j) else { return nil }
            return (100 + rest.0, j + rest.1 - i)
        }
        return small(i)
    }

    // MARK: Normalize

    public static func normalize(_ raw: String, manual: Bool = false) -> [Token] {
        let src = tokenize(raw)
        var out: [Token] = []
        var i = 0

        func previousAllowsNumber() -> Bool {
            guard let previous = out.last else { return false }
            if previous.book != nil || previous.number != nil { return true }
            return ["chapter", "verse", "verses"].contains(previous.word ?? "")
        }

        while i < src.count {
            let raw = src[i]

            // "the third chapter", "the twenty third psalm", "sixteenth verse"
            if let ordinal = parseOrdinal(src, i), i + ordinal.length < src.count {
                let target = src[i + ordinal.length].text
                if target == "chapter" || target == "verse" || target == "psalm" {
                    if target == "psalm" {
                        out.append(Token(kind: .book(BookMatch(key: "psalm", ids: ["PSA"], cued: true, heard: "psalm")), breakBefore: raw.breakBefore))
                    } else {
                        out.append(Token(kind: .word(target), breakBefore: raw.breakBefore))
                    }
                    out.append(Token(kind: .number(ordinal.value, compound: nil), breakBefore: false))
                    i += ordinal.length + 1
                    continue
                }
            }

            // A number straight after a book or "verse" is a number, not the start of a numbered book.
            let previous = out.last
            let allowPrefix = !(previous?.book != nil || ["chapter", "verse", "verses"].contains(previous?.word ?? ""))
            if let match = matchBook(src, i, manual: manual, allowPrefix: allowPrefix) {
                out.append(Token(kind: .book(match.book), breakBefore: raw.breakBefore))
                i = match.end
                continue
            }

            if let number = parseNumber(src, i, manual: manual) {
                out.append(Token(kind: .number(number.value, compound: number.compound), breakBefore: raw.breakBefore))
                i += number.length
                continue
            }

            if previousAllowsNumber(), let value = homophones[raw.text] {
                out.append(Token(kind: .number(value, compound: nil), breakBefore: raw.breakBefore))
                i += 1
                continue
            }

            if let keyword = keywords[raw.text], raw.text != "vs" || manual || previousAllowsNumber() {
                out.append(Token(kind: .word(keyword), breakBefore: raw.breakBefore))
            } else if previous?.number != nil, rangeWords.contains(raw.text) {
                out.append(Token(kind: .word("to"), breakBefore: raw.breakBefore))
            } else {
                out.append(Token(kind: .word(raw.text), breakBefore: raw.breakBefore))
            }
            i += 1
        }
        return out
    }
}
