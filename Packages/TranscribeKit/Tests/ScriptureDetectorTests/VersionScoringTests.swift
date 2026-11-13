import Foundation
import Testing
@testable import ScriptureDetector

/// Uses the real bundled translations from Transcribe/Resources/Bibles.
private let biblesDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Transcribe/Resources/Bibles")

private let bundled: [BibleTranslation] = {
    let files = (try? FileManager.default.contentsOfDirectory(at: biblesDirectory, includingPropertiesForKeys: nil)) ?? []
    return TranslationLibrary.load(bundled: files.filter { $0.pathExtension == "sqlite" }, importedDirectory: nil)
}()

private let john316 = BibleReference(book: "JHN", chapter: 3, verseStart: 16)

@Suite("Version scoring")
struct VersionScoringTests {
    @Test("All five public-domain translations are bundled")
    func bundledTranslations() {
        #expect(bundled.map(\.info.abbreviation) == ["KJV", "WEB", "BSB", "ASV", "YLT"])
        #expect(bundled.allSatisfy { $0.text(of: john316) != nil })
    }

    @Test("Alignment ignores words around the quote")
    func alignment() {
        let verse = ["for", "god", "so", "loved", "the", "world"]
        let spoken = ["he", "said", "for", "god", "so", "loved", "the", "world", "amen"]
        let a = VersionScorer.align(spoken: spoken, verse: verse)
        #expect(a.matched == 6)
        #expect(a.recall == 1)
        #expect(a.precision == 1)
    }

    @Test("Alignment tolerates small transcription errors")
    func fuzzyWords() {
        let a = VersionScorer.align(spoken: ["whosoever", "beleiveth", "in", "him"], verse: ["whosoever", "believeth", "in", "him"])
        #expect(a.matched == 4)
    }

    @Test("Picks the translation the speaker read from", arguments: [
        // As transcribed in a real on-device test: "belief" for "believeth".
        ("For God so love the world, that he gave his only begotten son, that whosoever belief in him should not perish, but have everlasting life.", "KJV"),
        ("For God so loved the world that He gave His one and only Son, that everyone who believes in Him shall not perish but have eternal life.", "BSB"),
        ("For God so loved the world, that he gave his one and only Son, that whoever believes in him should not perish, but have eternal life.", "WEB"),
        ("for God did so love the world, that His Son, the only begotten, He gave, that every one who is believing in him may not perish, but may have life age-during", "YLT"),
        ("For God so loved the world, that he gave his only begotten Son, that whosoever believeth on him should not perish, but have eternal life.", "ASV"),
    ])
    func picksVersion(spoken: String, expected: String) async throws {
        let detector = ScriptureDetector(translations: bundled)
        let scores = await detector.scoreVersions(spoken: spoken, reference: john316)
        let best = try #require(scores.first)
        #expect(best.abbreviation == expected)
        #expect(best.score > 0.75)
    }

    @Test("Preferred version wins a tie")
    func tieBreak() async {
        let detector = ScriptureDetector(translations: bundled)
        // KJV and ASV read identically here.
        let spoken = "In the beginning God created the heavens and the earth"
        let ref = BibleReference(book: "GEN", chapter: 1, verseStart: 1)
        let scores = await detector.scoreVersions(spoken: spoken, reference: ref, preferred: "BSB")
        #expect(scores.first?.abbreviation == "BSB")
    }

    @Test("Named versions", arguments: [
        ("in the NIV it says", "NIV"),
        ("the New King James puts it this way", "NKJV"),
        ("my King James says", "KJV"),
        ("reading from the English Standard Version", "ESV"),
        ("Young's Literal Translation renders it", "YLT"),
    ])
    func namedVersions(text: String, expected: String) {
        #expect(VersionNameDetector.detect(in: text) == expected)
    }

    @Test("No version named")
    func noVersion() {
        #expect(VersionNameDetector.detect(in: "this is a message for the whole church") == nil)
    }

    @Test("Finds verses quoted without a reference")
    func quotes() async throws {
        let detector = ScriptureDetector(translations: bundled)
        await detector.prepareQuoteIndex()
        let spoken = "and remember church, Trust in the Lord with all thine heart; and lean not unto thine own understanding. Amen."
        let matches = await detector.quotedVerses(in: spoken)
        let match = try #require(matches.first)
        #expect(match.reference.description == "Proverbs 3:5")
        #expect(match.best.abbreviation == "KJV")

        // John 3:15 shares "whosoever believeth in him should not perish" with 3:16.
        let john = await detector.quotedVerses(in: "For God so loved the world, that he gave his only begotten Son, that whosoever believeth in him should not perish, but have everlasting life.")
        #expect(john.map(\.reference.description) == ["John 3:16"])

        let sermon = "Today I want to talk about how we treat our neighbours and how we spend our time this week."
        #expect(await detector.quotedVerses(in: sermon).isEmpty)
    }
}
