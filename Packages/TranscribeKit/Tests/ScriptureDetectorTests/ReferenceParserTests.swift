import Testing
@testable import ScriptureDetector

private func refs(_ text: String) -> [String] {
    ReferenceParser.parse(text).map(\.reference.description)
}

@Suite("Reference parser: spoken and written forms")
struct ReferenceParserTests {
    @Test("Written references from the transcriber", arguments: [
        ("Please turn with me to John 3:16.", "John 3:16"),
        ("John chapter 3, verse 16", "John 3:16"),
        ("Read 1 Corinthians 13:4-7 with me", "1 Corinthians 13:4-7"),
        ("Romans 8:28", "Romans 8:28"),
        ("Psalm 23", "Psalm 23"),
        ("in Genesis 1:1", "Genesis 1:1"),
        ("Revelation 21:4", "Revelation 21:4"),
    ])
    func written(text: String, expected: String) {
        #expect(refs(text) == [expected])
    }

    @Test("Spoken numbers and ordinals", arguments: [
        ("first Corinthians chapter thirteen verse four", "1 Corinthians 13:4"),
        ("John three sixteen", "John 3:16"),
        ("second Timothy three sixteen", "2 Timothy 3:16"),
        ("Romans chapter eight verses twenty eight through thirty", "Romans 8:28-30"),
        ("the twenty third psalm", "Psalm 23"),
        ("Psalm one nineteen verse one oh five", "Psalm 119:105"),
        ("Psalm one hundred and nineteen verse a hundred and five", "Psalm 119:105"),
        ("the third chapter of John verse sixteen", "John 3:16"),
        ("chapter five of Matthew verse three", "Matthew 5:3"),
        ("verse sixteen of John chapter three", "John 3:16"),
        ("Jude verse twenty four", "Jude 24"),
        ("Philippians four thirteen", "Philippians 4:13"),
        ("Isaiah forty, verse thirty one", "Isaiah 40:31"),
        ("third John verse two", "3 John 2"),
        ("Hebrews eleven and verse one", "Hebrews 11:1"),
    ])
    func spoken(text: String, expected: String) {
        #expect(refs(text) == [expected])
    }

    @Test("Book name variants and mishearings", arguments: [
        ("the gospel according to Saint Matthew chapter five", "Matthew 5"),
        ("the book of Ecclesiastics chapter three", "Ecclesiastes 3"),
        ("Phillipians 4:6", "Philippians 4:6"),
        ("the epistle to the Ephesians chapter two verse eight", "Ephesians 2:8"),
        ("Song of Songs chapter two", "Song of Solomon 2"),
        ("Revelations 3:20", "Revelation 3:20"),
    ])
    func variants(text: String, expected: String) {
        #expect(refs(text) == [expected])
    }

    @Test("Run-together numbers from the transcriber", arguments: [
        ("John 316.", "John 3:16"),
        ("Romans 828", "Romans 8:28"),
        ("Genesis 1215", "Genesis 12:15"),
        ("1 Corinthians 134 through 7", "1 Corinthians 13:4-7"),
        ("Psalm 119", "Psalm 119"),
    ])
    func runTogether(text: String, expected: String) throws {
        let result = try #require(ReferenceParser.parse(text).first)
        #expect(result.reference.description == expected)
        #expect(result.confidence >= 0.75)
    }

    @Test("More spoken forms", arguments: [
        ("Turn to Matthew five, verses three to twelve", "Matthew 5:3-12"),
        ("Genesis one one", "Genesis 1:1"),
        ("Second Kings chapter two verse eleven", "2 Kings 2:11"),
        ("1st Peter 5:7", "1 Peter 5:7"),
        ("Ephesians 2 8 through 10", "Ephesians 2:8-10"),
        ("Isaiah 53", "Isaiah 53"),
        ("Psalm 23 verse 1", "Psalm 23:1"),
        ("third John chapter one verse four", "3 John 4"),
        ("Romans chapter twelve verses one and two", "Romans 12:1-2"),
        ("John 3:16-18", "John 3:16-18"),
        ("Hebrews 11, beginning at verse 1", "Hebrews 11:1"),
        ("first Thessalonians five seventeen", "1 Thessalonians 5:17"),
        ("Lamentations three twenty two to twenty three", "Lamentations 3:22-23"),
        ("Micah 6:8", "Micah 6:8"),
    ])
    func moreSpoken(text: String, expected: String) {
        #expect(refs(text) == [expected])
    }

    @Test("Relative references need the passage being discussed", arguments: [
        ("Now look at the next verse.", "John 3:17"),
        ("and the following verse says", "John 3:17"),
        ("go back to the previous verse", "John 3:15"),
        ("read verses 16 through 18", "John 3:16-18"),
        ("Look at verse twenty", "John 3:20"),
        ("chapter four verse one", "John 4:1"),
    ])
    func relative(text: String, expected: String) throws {
        let context = BibleReference(book: "JHN", chapter: 3, verseStart: 16)
        let result = try #require(ReferenceParser.parse(text, context: context).first)
        #expect(result.reference.description == expected)
        #expect(ReferenceParser.parse(text).isEmpty)
    }

    @Test("The next verse crosses into the next chapter")
    func nextVerseCrossesChapter() {
        let context = BibleReference(book: "JHN", chapter: 3, verseStart: 36)
        #expect(ReferenceParser.parse("the next verse", context: context).first?.reference.description == "John 4:1")
        let start = BibleReference(book: "JHN", chapter: 4, verseStart: 1)
        #expect(ReferenceParser.parse("the previous verse", context: start).first?.reference.description == "John 3:36")
    }

    @Test("An earlier reference in the same line becomes the context")
    func contextFromSameLine() {
        #expect(refs("Romans 8:28, and then the next verse") == ["Romans 8:28", "Romans 8:29"])
    }

    @Test("Transcript lines are rewritten with written references", arguments: [
        ("John 316 NIV version.", "John 3:16 NIV version."),
        ("Please turn with me to John chapter three, verse sixteen.", "Please turn with me to John 3:16."),
        ("First Corinthians thirteen verses four through seven", "1 Corinthians 13:4-7"),
        ("Open to the twenty third psalm.", "Open to Psalm 23."),
        ("the third chapter of John verse sixteen says", "John 3:16 says"),
        ("Proverbs 3 verses 5 and 7", "Proverbs 3:5, 7"),
        ("Read the book of Romans chapter eight", "Read the book of Romans 8"),
        ("and James 2 said to me", "and James 2 said to me"),
        ("God so loved the world", "God so loved the world"),
    ])
    func rewrite(text: String, expected: String) {
        #expect(ReferenceParser.rewrite(text, references: ReferenceParser.parse(text)) == expected)
    }

    @Test("Relative references are rewritten against the context")
    func rewriteRelative() {
        let context = BibleReference(book: "JHN", chapter: 3, verseStart: 16)
        let text = "Look at the next verse, and then verses 18 through 20."
        let found = ReferenceParser.parse(text, context: context)
        #expect(ReferenceParser.rewrite(text, references: found) == "Look at the next verse (John 3:17), and then John 3:18-20.")
    }

    @Test("Separate verses become separate references")
    func separateVerses() {
        #expect(refs("Romans 12 verses 1 and 2") == ["Romans 12:1-2"])
        #expect(refs("Proverbs 3 verses 5 and 7") == ["Proverbs 3:5", "Proverbs 3:7"])
    }

    @Test("Ordinary speech is not a reference", arguments: [
        "John three times told me",
        "Pastor John three weeks ago",
        "Mark two people over there",
        "I went to see James 5 years ago",
        "We have four things to talk about",
        "God so loved the world",
    ])
    func notReferences(text: String) {
        #expect(refs(text).isEmpty)
    }

    @Test("Impossible references are rejected")
    func invalid() {
        #expect(refs("John 30:1").isEmpty)
        #expect(refs("Jude 2:1").isEmpty)
    }

    @Test("A missing book number asks for confirmation")
    func bareNumberedBook() throws {
        let result = try #require(ReferenceParser.parse("Corinthians thirteen verse four").first)
        #expect(result.reference.description == "1 Corinthians 13:4")
        #expect(result.alternatives.map(\.description) == ["2 Corinthians 13:4"])
        #expect(result.confidence < 0.75)
    }

    @Test("A name followed by one number is low confidence")
    func namelike() throws {
        let result = try #require(ReferenceParser.parse("and James 2 said").first)
        #expect(result.reference.description == "James 2")
        #expect(result.confidence < 0.75)
    }

    @Test("Manual references accept abbreviations")
    func manual() {
        #expect(ReferenceParser.parseManual("1 cor 13:4-7")?.reference.description == "1 Corinthians 13:4-7")
        #expect(ReferenceParser.parseManual("jn 3:16")?.reference.description == "John 3:16")
        #expect(ReferenceParser.parseManual("ps 23")?.reference.description == "Psalm 23")
    }

    @Test("Reference keys and validity")
    func referenceBasics() {
        let ref = BibleReference(book: "JHN", chapter: 3, verseStart: 16)
        #expect(ref.key == "JHN.3.16-16")
        #expect(ref.isValid)
        #expect(!BibleReference(book: "JHN", chapter: 3, verseStart: 40).isValid)
        #expect(Books.resolve(name: "First Corinthians") == "1CO")
        #expect(Books.resolve(name: "Jhn") == "JHN")
    }
}
