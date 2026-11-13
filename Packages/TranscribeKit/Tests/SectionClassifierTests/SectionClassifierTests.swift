import Testing
@testable import SectionClassifier

@Suite("Section classification without Apple Intelligence")
struct KeywordClassifierTests {
    @Test("Telltale phrases pick the section", arguments: [
        ("Good morning and welcome! If this is your first time, we're glad you're here.", ServiceSectionKind.welcome),
        ("Let's bow our heads. Heavenly Father, we thank you. In Jesus' name, amen.", .prayer),
        ("This week the youth group meets Wednesday. Sign up for the picnic in the foyer.", .announcements),
        ("Turn with me to Romans 8. Read with me.", .scriptureReading),
        ("As the ushers come, remember God loves a cheerful giver. Give online or use the envelope.", .offering),
        ("With every head bowed, if you want to receive Christ, raise your hand. Come forward.", .altarCall),
        ("May the Lord bless you and keep you. Go in peace, see you next week.", .closing),
    ])
    func cues(text: String, expected: ServiceSectionKind) {
        let decision = KeywordSectionClassifier.classify(text)
        #expect(decision.kind == expected)
        #expect(decision.confidence >= 0.6)
    }

    @Test("No cues means low confidence")
    func noCues() {
        #expect(KeywordSectionClassifier.classify("Abraham waited twenty five years for a son.").confidence < 0.5)
    }
}

@Suite("Summary parsing")
struct SummaryParsingTests {
    @Test("Reads the plain-text summary layout")
    func parse() {
        let text = """
        **TITLE:** "Waiting on the Lord"

        - Abraham waited for God's promise.
        • Faith trusts God when nothing seems to happen.
        3. Waiting means letting God be God.

        TAKEAWAY: Pray and trust God's timing.
        """
        let summary = SermonSummarizer.parse(text)
        #expect(summary.title == "Waiting on the Lord")
        #expect(summary.keyPoints == ["Abraham waited for God's promise.", "Faith trusts God when nothing seems to happen.", "Waiting means letting God be God."])
        #expect(summary.takeaway == "Pray and trust God's timing.")
    }
}
