import Foundation

/// A book of the 66-book Protestant canon, identified by its USFM code ("JHN", "1CO").
public struct BibleBook: Sendable, Hashable {
    public let id: String
    public let name: String
    /// "Psalm 23" rather than "Psalms 23".
    public let singular: String?
    /// Spoken variants and common spellings, normalized silently.
    public let aliases: [String]
    /// Likely mishearings that are also ordinary words; matched only when a number follows.
    public let misheard: [String]
    /// Written abbreviations, accepted in manually typed references.
    public let abbreviations: [String]
    /// The name is also an ordinary word or first name ("Mark", "James", "Job").
    public let isCommonWord: Bool

    init(_ id: String, _ name: String, singular: String? = nil, aliases: [String] = [], misheard: [String] = [], abbr: [String] = [], common: Bool = false) {
        self.id = id
        self.name = name
        self.singular = singular
        self.aliases = aliases
        self.misheard = misheard
        self.abbreviations = abbr
        self.isCommonWord = common
    }
}

public enum Books {
    public static let canonicalOrder: [String] = ("GEN EXO LEV NUM DEU JOS JDG RUT 1SA 2SA 1KI 2KI 1CH 2CH EZR NEH EST JOB PSA PRO ECC SNG ISA JER LAM "
        + "EZK DAN HOS JOL AMO OBA JON MIC NAM HAB ZEP HAG ZEC MAL MAT MRK LUK JHN ACT ROM 1CO 2CO GAL EPH PHP COL "
        + "1TH 2TH 1TI 2TI TIT PHM HEB JAS 1PE 2PE 1JN 2JN 3JN JUD REV").split(separator: " ").map(String.init)

    public static let all: [BibleBook] = [
        BibleBook("GEN", "Genesis", aliases: ["genisis", "jenesis", "geneses"], abbr: ["gen", "gn"]),
        BibleBook("EXO", "Exodus", aliases: ["exodis", "exedus"], abbr: ["exo", "exod", "ex"]),
        BibleBook("LEV", "Leviticus", aliases: ["levitikus", "leviticous"], abbr: ["lev", "lv"]),
        BibleBook("NUM", "Numbers", abbr: ["num", "nm"], common: true),
        BibleBook("DEU", "Deuteronomy", aliases: ["duteronomy", "deutoronomy", "deuteronomie"], abbr: ["deut", "deu", "dt"]),
        BibleBook("JOS", "Joshua", abbr: ["josh", "jos"], common: true),
        BibleBook("JDG", "Judges", misheard: ["judge"], abbr: ["judg", "jdg"], common: true),
        BibleBook("RUT", "Ruth", abbr: ["rut", "ru"], common: true),
        BibleBook("1SA", "1 Samuel"), BibleBook("2SA", "2 Samuel"),
        BibleBook("1KI", "1 Kings"), BibleBook("2KI", "2 Kings"),
        BibleBook("1CH", "1 Chronicles"), BibleBook("2CH", "2 Chronicles"),
        BibleBook("EZR", "Ezra", abbr: ["ezr"], common: true),
        BibleBook("NEH", "Nehemiah", aliases: ["nehemia", "neemiah"], abbr: ["neh"]),
        BibleBook("EST", "Esther", aliases: ["ester"], abbr: ["esth", "est"], common: true),
        BibleBook("JOB", "Job", abbr: ["jb"], common: true),
        BibleBook("PSA", "Psalms", singular: "Psalm", aliases: ["psalm", "salm", "salms", "psalm number", "psalms number"], misheard: ["sam", "sams", "palm", "palms"], abbr: ["ps", "psa", "pss"]),
        BibleBook("PRO", "Proverbs", aliases: ["proverb"], abbr: ["prov", "pro", "prv"]),
        BibleBook("ECC", "Ecclesiastes", aliases: ["ecclesiastics", "ecclesiasties", "eclesiastes", "ecclesiastis"], abbr: ["eccl", "ecc", "eccles"]),
        BibleBook("SNG", "Song of Solomon", aliases: ["song of songs", "songs of solomon", "song of solomons", "canticles"], abbr: ["song", "sos", "sg"]),
        BibleBook("ISA", "Isaiah", aliases: ["isiah", "isaia", "isaiahs", "esaias"], abbr: ["isa", "is"]),
        BibleBook("JER", "Jeremiah", aliases: ["jeramiah", "jeremia", "jeremias"], abbr: ["jer"]),
        BibleBook("LAM", "Lamentations", aliases: ["lamentation"], abbr: ["lam"]),
        BibleBook("EZK", "Ezekiel", aliases: ["ezekial", "ezeikel", "ezikiel"], abbr: ["ezek", "ezk", "eze"]),
        BibleBook("DAN", "Daniel", abbr: ["dan", "dn"], common: true),
        BibleBook("HOS", "Hosea", aliases: ["hoseah", "hosaya"], abbr: ["hos"], common: true),
        BibleBook("JOL", "Joel", abbr: ["jl"], common: true),
        BibleBook("AMO", "Amos", abbr: ["am"], common: true),
        BibleBook("OBA", "Obadiah", aliases: ["obediah", "obadia"], abbr: ["obad", "ob"]),
        BibleBook("JON", "Jonah", aliases: ["jona"], abbr: ["jnh"], common: true),
        BibleBook("MIC", "Micah", aliases: ["micha", "mica"], abbr: ["mic", "mi"], common: true),
        BibleBook("NAM", "Nahum", aliases: ["naham", "nayhum"], abbr: ["nah", "na"], common: true),
        BibleBook("HAB", "Habakkuk", aliases: ["habakuk", "habbakuk", "habacuc", "habakkuks", "habbakkuk"], abbr: ["hab"]),
        BibleBook("ZEP", "Zephaniah", aliases: ["zefaniah", "zephania"], abbr: ["zeph", "zep"]),
        BibleBook("HAG", "Haggai", aliases: ["hagai", "haggi", "haggay"], abbr: ["hag"]),
        BibleBook("ZEC", "Zechariah", aliases: ["zachariah", "zecharia", "zacharias", "zacharia"], abbr: ["zech", "zec"]),
        BibleBook("MAL", "Malachi", aliases: ["malachai", "malaki", "malachy"], abbr: ["mal"]),
        BibleBook("MAT", "Matthew", aliases: ["mathew", "matthews", "mathews"], abbr: ["matt", "mat", "mt"], common: true),
        BibleBook("MRK", "Mark", misheard: ["marks"], abbr: ["mrk", "mk"], common: true),
        BibleBook("LUK", "Luke", aliases: ["lukes"], abbr: ["luk", "lk"], common: true),
        BibleBook("JHN", "John", aliases: ["jon"], abbr: ["jn", "jhn"], common: true),
        BibleBook("ACT", "Acts", aliases: ["acts of the apostles"], misheard: ["act"], abbr: ["ac"], common: true),
        BibleBook("ROM", "Romans", misheard: ["roman", "romance"], abbr: ["rom", "rm"]),
        BibleBook("1CO", "1 Corinthians"), BibleBook("2CO", "2 Corinthians"),
        BibleBook("GAL", "Galatians", aliases: ["galatian", "galations"], misheard: ["galicians"], abbr: ["gal"]),
        BibleBook("EPH", "Ephesians", aliases: ["ephesian", "ephesions"], abbr: ["eph"]),
        BibleBook("PHP", "Philippians", aliases: ["phillipians", "philipians", "philippian", "phillippians"], misheard: ["philippines", "filipinos", "philippine"], abbr: ["phil", "php"]),
        BibleBook("COL", "Colossians", aliases: ["colossian", "collosians", "colosians"], misheard: ["collisions"], abbr: ["col"]),
        BibleBook("1TH", "1 Thessalonians"), BibleBook("2TH", "2 Thessalonians"),
        BibleBook("1TI", "1 Timothy"), BibleBook("2TI", "2 Timothy"),
        BibleBook("TIT", "Titus", aliases: ["tidus"], abbr: ["tit"], common: true),
        BibleBook("PHM", "Philemon", aliases: ["filemon", "philamon"], abbr: ["phlm", "phm", "philem"]),
        BibleBook("HEB", "Hebrews", misheard: ["hebrew"], abbr: ["heb"]),
        BibleBook("JAS", "James", abbr: ["jas", "jms"], common: true),
        BibleBook("1PE", "1 Peter"), BibleBook("2PE", "2 Peter"),
        BibleBook("1JN", "1 John"), BibleBook("2JN", "2 John"), BibleBook("3JN", "3 John"),
        BibleBook("JUD", "Jude", abbr: ["jud"], common: true),
        BibleBook("REV", "Revelation", aliases: ["revelations", "revelation of john", "revelation of saint john"], misheard: ["revolution", "revolutions"], abbr: ["rev", "rv"]),
    ]

    /// Books that are only named with a leading number ("First Corinthians"). John alone means the Gospel.
    struct NumberedBase: Sendable {
        let key: String
        let ids: [Int: String]
        let defaultID: String?
        let aliases: [String]
        let abbreviations: [String]
    }

    static let numberedBases: [NumberedBase] = [
        NumberedBase(key: "samuel", ids: [1: "1SA", 2: "2SA"], defaultID: nil, aliases: ["samuels"], abbreviations: ["sam", "sa"]),
        NumberedBase(key: "kings", ids: [1: "1KI", 2: "2KI"], defaultID: nil, aliases: [], abbreviations: ["kgs", "ki"]),
        NumberedBase(key: "chronicles", ids: [1: "1CH", 2: "2CH"], defaultID: nil, aliases: ["chronicle"], abbreviations: ["chron", "chr", "ch"]),
        NumberedBase(key: "corinthians", ids: [1: "1CO", 2: "2CO"], defaultID: nil, aliases: ["corinthian", "carinthians", "corinthains", "corrinthians"], abbreviations: ["cor", "co"]),
        NumberedBase(key: "thessalonians", ids: [1: "1TH", 2: "2TH"], defaultID: nil, aliases: ["thessalonian", "thessalonica", "thesalonians"], abbreviations: ["thess", "thes", "th"]),
        NumberedBase(key: "timothy", ids: [1: "1TI", 2: "2TI"], defaultID: nil, aliases: ["timmothy"], abbreviations: ["tim", "ti"]),
        NumberedBase(key: "peter", ids: [1: "1PE", 2: "2PE"], defaultID: nil, aliases: [], abbreviations: ["pet", "pe", "pt"]),
        NumberedBase(key: "john", ids: [1: "1JN", 2: "2JN", 3: "3JN"], defaultID: "JHN", aliases: ["jon"], abbreviations: ["jn", "jhn"]),
    ]

    public static let singleChapterBooks: Set<String> = ["OBA", "PHM", "2JN", "3JN", "JUD"]

    private static let byID: [String: BibleBook] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    public static func book(_ id: String) -> BibleBook? { byID[id] }

    /// "Psalm" when a chapter follows, otherwise the book's name.
    public static func displayName(_ id: String, withChapter: Bool = true) -> String {
        guard let book = byID[id] else { return id }
        return withChapter ? (book.singular ?? book.name) : book.name
    }

    /// Resolves a written or spoken book name ("1 Cor", "First Corinthians", "Psalms", "jhn").
    public static func resolve(name: String) -> String? {
        let tokens = SpokenReferenceNormalizer.normalize(name, manual: true)
        if tokens.count == 1, case .book(let match) = tokens[0].kind, match.ids.count == 1 { return match.ids[0] }
        if let book = byID[name.uppercased()] { return book.id }
        return nil
    }
}
