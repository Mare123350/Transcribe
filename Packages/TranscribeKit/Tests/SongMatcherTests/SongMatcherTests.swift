import Foundation
import Testing
@testable import SongMatcher

/// The bundled library from Transcribe/Resources/songs.json.
private let library: [SongRecord] = {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Transcribe/Resources/songs.json")
    return (try? SongImporter.songs(fromJSON: Data(contentsOf: url))) ?? []
}()

private let matcher = SongMatcher(songs: library)

@Suite("Song matching")
struct SongMatcherTests {
    @Test("Library loads")
    func libraryLoads() {
        #expect(library.count >= 10)
    }

    @Test("Recognizes messy sung transcriptions", arguments: [
        // Dropped and misheard words, as speech-to-text produces from singing.
        ("amazing grace how sweet the sound that save a wrench like me I once was lost but now I'm found was blind but now I see", "Amazing Grace", "Verse 1"),
        ("when peace like a river attended my way when sorrows like sea billows roll whatever my lot thou has taught me to say", "It Is Well with My Soul", "Verse 1"),
        ("this is my story this is my song praising my savior all the day long this is my story", "Blessed Assurance", "Chorus"),
        ("prone to wander lord I feel it prone to leave the god I love here's my heart oh take and seal it", "Come, Thou Fount of Every Blessing", "Verse 3"),
        ("what a friend we have in jesus all our sins and grief to bear what a privilege to carry everything to god in prayer", "What a Friend We Have in Jesus", "Verse 1"),
    ])
    func recognizes(sung: String, title: String, section: String) throws {
        let match = try #require(matcher.match(text: sung))
        #expect(match.title == title)
        #expect(match.sectionName == section)
        #expect(match.confidence >= 0.55)
    }

    @Test("A window spanning two sections still matches the song")
    func acrossSections() throws {
        let sung = "was blind but now I see twas grace that taught my heart to fear and grace my fears relieved"
        let match = try #require(matcher.match(text: sung))
        #expect(match.title == "Amazing Grace")
        #expect(match.confidence >= 0.55)
    }

    @Test("Ordinary speech doesn't match a song", arguments: [
        "good morning church it's so good to see everyone here today please find a seat and let's get started",
        "this week we're collecting for the food bank so bring what you can and drop it at the back by the doors",
        "god's grace is amazing and his love for us never runs out even when we wander away from him",
        "let's pray father we thank you for this day and for your word to us this morning in jesus name amen",
    ])
    func speechDoesNotMatch(text: String) {
        let confidence = matcher.match(text: text)?.confidence ?? 0
        #expect(confidence < 0.55)
    }

    @Test("Too few words is not enough to decide")
    func tooShort() {
        #expect(matcher.match(text: "amazing grace") == nil)
    }
}

@Suite("Song tracker")
struct SongTrackerTests {
    private func match(_ title: String, section: Int = 0, confidence: Double) -> SongMatch {
        SongMatch(songID: UUID(uuidString: title == "A" ? "00000000-0000-0000-0000-00000000000A" : "00000000-0000-0000-0000-00000000000B")!, title: title, sectionIndex: section, sectionName: "Verse \(section + 1)", confidence: confidence)
    }

    @Test("A strong match starts a song immediately")
    func strongStart() {
        var tracker = SongTracker()
        #expect(tracker.update(match("A", confidence: 0.85), at: 0) == [.started(match("A", confidence: 0.85))])
    }

    @Test("A moderate match needs two windows in a row")
    func moderateStart() {
        var tracker = SongTracker()
        #expect(tracker.update(match("A", confidence: 0.6), at: 0).isEmpty)
        #expect(tracker.update(match("A", confidence: 0.62), at: 4) == [.started(match("A", confidence: 0.62))])
    }

    @Test("Section changes are reported")
    func sectionChange() {
        var tracker = SongTracker()
        _ = tracker.update(match("A", confidence: 0.9), at: 0)
        #expect(tracker.update(match("A", section: 1, confidence: 0.8), at: 5) == [.sectionChanged(match("A", section: 1, confidence: 0.8))])
    }

    @Test("The song ends after about 15 seconds without a good match")
    func ends() {
        var tracker = SongTracker()
        _ = tracker.update(match("A", confidence: 0.9), at: 0)
        #expect(tracker.update(match("A", confidence: 0.4), at: 10).isEmpty)  // still above the continue threshold
        #expect(tracker.update(nil, at: 20).isEmpty)                         // 10 s since the last good match
        #expect(tracker.tick(at: 24).isEmpty)
        #expect(tracker.tick(at: 26) == [.ended(songID: match("A", confidence: 0).songID)])
        #expect(tracker.current == nil)
    }

    @Test("A dismissed song isn't detected again straight away")
    func dismissed() {
        var tracker = SongTracker()
        _ = tracker.update(match("A", confidence: 0.9), at: 0)
        tracker.dismiss(match("A", confidence: 0).songID, at: 1)
        #expect(tracker.update(match("A", confidence: 0.9), at: 5).isEmpty)
        #expect(tracker.update(match("A", confidence: 0.9), at: 400) == [.started(match("A", confidence: 0.9))])
    }

    @Test("Switching straight to another song")
    func switching() {
        var tracker = SongTracker()
        _ = tracker.update(match("A", confidence: 0.9), at: 0)
        let events = tracker.update(match("B", confidence: 0.85), at: 5)
        #expect(events == [.ended(songID: match("A", confidence: 0).songID), .started(match("B", confidence: 0.85))])
    }
}

@Suite("Song import")
struct SongImporterTests {
    @Test("Plain text with section headings")
    func headings() throws {
        let text = """
        Grace Song
        Artist: Our Worship Team

        [Verse 1]
        First line of the verse
        Second line of the verse

        Chorus:
        We sing the chorus here

        BRIDGE
        Bridge line
        """
        let song = try #require(SongImporter.songs(fromText: text).first)
        #expect(song.title == "Grace Song")
        #expect(song.artist == "Our Worship Team")
        #expect(song.sections.map(\.name) == ["Verse 1", "Chorus", "Bridge"])
        #expect(song.sections[0].lyrics == "First line of the verse\nSecond line of the verse")
    }

    @Test("Plain text without headings: repeated block becomes the chorus")
    func blocks() throws {
        let text = "Simple Song\n\nverse one words\n\nchorus words\n\nverse two words\n\nchorus words\n"
        let song = try #require(SongImporter.songs(fromText: text).first)
        #expect(song.sections.map(\.name) == ["Verse 1", "Chorus", "Verse 2"])
    }

    @Test("Several songs in one file")
    func several() {
        let songs = SongImporter.songs(fromText: "One\n\nla la\n---\nTwo\n\nda da")
        #expect(songs.map(\.title) == ["One", "Two"])
    }

    @Test("JSON round trip")
    func json() throws {
        let data = try SongImporter.json(for: Array(library.prefix(2)))
        let back = try SongImporter.songs(fromJSON: data)
        #expect(back == Array(library.prefix(2)))
    }
}

@Suite("Folding sung lines")
struct SegmentBelongsTests {
    @Test("Lines of the song belong; announcements after it don't")
    func belongs() throws {
        let id = try #require(library.first { $0.title == "Amazing Grace" }?.id)
        let tokens = { (text: String) in text.lowercased().split(separator: " ").map(String.init) }
        #expect(matcher.segmentBelongs(tokens("amazing grace how sweet the sound that saved a wretch like me"), to: id))
        #expect(matcher.segmentBelongs(tokens("how precious did that grace appear"), to: id))
        #expect(!matcher.segmentBelongs(tokens("amen"), to: id))
        #expect(!matcher.segmentBelongs(tokens("you may be seated"), to: id))
        #expect(!matcher.segmentBelongs(tokens("this week we have a church picnic on saturday afternoon"), to: id))
    }
}
