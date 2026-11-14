import Testing
@testable import TranscribeCore

@Suite("Splitting passages into slides")
struct SlideSplitterTests {
    @Test("Short passages stay on one slide")
    func short() {
        #expect(SlideSplitter.split(["16 For God so loved the world.", "17 For God sent not his Son."], maxWords: 40).count == 1)
    }

    @Test("Verses are kept whole and slides stay under the limit")
    func wholeVerses() {
        let verses = (1...10).map { "\($0) " + Array(repeating: "word", count: 14).joined(separator: " ") + "." }
        let slides = SlideSplitter.split(verses, maxWords: 40)
        #expect(slides.count == 5)
        #expect(slides.allSatisfy { SlideSplitter.wordCount($0) <= 40 })
        #expect(slides[0].hasPrefix("1 ") && slides[1].hasPrefix("3 "))
    }

    @Test("A long verse breaks at sentences, then clauses, never mid-word")
    func longVerse() {
        let verse = "1 In the beginning was the Word, and the Word was with God, and the Word was God. The same was in the beginning with God; all things were made by him, and without him was not any thing made that was made."
        let slides = SlideSplitter.split([verse], maxWords: 20)
        #expect(slides.count >= 2)
        #expect(slides.allSatisfy { SlideSplitter.wordCount($0) <= 20 })
        #expect(slides.joined(separator: " ").split(separator: " ") == verse.split(separator: " "))
    }

    @Test("A tiny last slide joins the one before")
    func noOrphans() {
        let slides = SlideSplitter.split(["1 " + Array(repeating: "word", count: 38).joined(separator: " "), "2 Amen."], maxWords: 40)
        #expect(slides.count == 1)
    }
}
