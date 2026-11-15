import Foundation
import Testing
@testable import SongMatcher

private func file(_ name: String, _ text: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: "song-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: name)
    try text.write(to: url, atomically: true, encoding: .utf8)
    return url
}

@Suite("Importing songs")
struct SongImportFormatTests {
    @Test("ChordPro: metadata, chords removed, environments and comments as sections")
    func chordPro() throws {
        let url = try file("grace.cho", """
            {title: Amazing Grace}
            {artist: John Newton}
            {ccli: 22025}
            {copyright: Public Domain}
            # a comment line
            {comment: Verse 1}
            A[G]mazing [G7]grace, how [C]sweet the [G]sound
            That [G]saved a wretch like [D]me

            {start_of_chorus}
            My [C]chains are gone, I've been set free
            {end_of_chorus}

            'Twas grace that taught my heart to fear
            """)
        let song = try #require(SongImporter.songs(from: url).first)
        #expect(song.title == "Amazing Grace")
        #expect(song.artist == "John Newton")
        #expect(song.ccliNumber == "22025")
        #expect(song.sections.map(\.name) == ["Verse 1", "Chorus", "Verse 2"])
        #expect(song.sections[0].lyrics == "Amazing grace, how sweet the sound\nThat saved a wretch like me")
    }

    @Test("OpenLyrics: titles, authors, CCLI number, themes, verse order")
    func openLyrics() throws {
        let url = try file("song.xml", """
            <?xml version="1.0" encoding="UTF-8"?>
            <song xmlns="http://openlyrics.info/namespace/2009/song" version="0.8">
              <properties>
                <titles><title>Be Thou My Vision</title></titles>
                <authors><author>Dallan Forgaill</author><author>Mary Byrne</author></authors>
                <ccliNo>30639</ccliNo>
                <themes><theme>Devotion</theme></themes>
                <verseOrder>v1 c v2</verseOrder>
              </properties>
              <lyrics>
                <verse name="v1"><lines>Be thou my vision<br/>O Lord of my heart</lines></verse>
                <verse name="v2"><lines>Be thou my wisdom<br/><comment>softly</comment>And thou my true word</lines></verse>
                <verse name="c"><lines>High King of heaven</lines></verse>
              </lyrics>
            </song>
            """)
        let song = try #require(SongImporter.songs(from: url).first)
        #expect(song.title == "Be Thou My Vision")
        #expect(song.artist == "Dallan Forgaill, Mary Byrne")
        #expect(song.ccliNumber == "30639")
        #expect(song.themes == ["Devotion"])
        #expect(song.sections.map(\.name) == ["Verse 1", "Chorus", "Verse 2"])
        #expect(song.sections[2].lyrics == "Be thou my wisdom\nAnd thou my true word")
    }

    @Test("SongSelect .usr")
    func usr() throws {
        let url = try file("song.usr", """
            [File]
            Type=SongSelect Import File
            Version=3.0
            [S A4768151]
            Title=How Great Is Our God
            Author=Chris Tomlin | Ed Cash | Jesse Reeves
            Copyright=2004 worshiptogether.com songs
            Themes=Majesty/tPraise
            Fields=Verse 1/tChorus
            Words=The splendor of the King/nClothed in majesty/tHow great is our God/nSing with me
            """)
        let song = try #require(SongImporter.songs(from: url).first)
        #expect(song.title == "How Great Is Our God")
        #expect(song.ccliNumber == "4768151")
        #expect(song.artist == "Chris Tomlin, Ed Cash, Jesse Reeves")
        #expect(song.themes == ["Majesty", "Praise"])
        #expect(song.sections.map(\.name) == ["Verse 1", "Chorus"])
        #expect(song.sections[1].lyrics == "How great is our God\nSing with me")
    }

    @Test("SongSelect plain-text download")
    func songSelectText() throws {
        let url = try file("How Great Is Our God.txt", """
            How Great Is Our God

            Verse 1
            The splendor of the King
            Clothed in majesty

            Chorus
            How great is our God
            Sing with me

            CCLI Song # 4348399
            Chris Tomlin | Ed Cash | Jesse Reeves
            © 2004 sixsteps Music
            For use solely with the SongSelect® Terms of Use. All rights reserved. www.ccli.com
            CCLI License # 1234567
            """)
        let song = try #require(SongImporter.songs(from: url).first)
        #expect(song.title == "How Great Is Our God")
        #expect(song.ccliNumber == "4348399")
        #expect(song.artist == "Chris Tomlin, Ed Cash, Jesse Reeves")
        #expect(song.copyright == "© 2004 sixsteps Music")
        #expect(song.sections.map(\.name) == ["Verse 1", "Chorus"])
        #expect(!song.sections.contains { $0.lyrics.contains("CCLI") })
    }

    @Test("Older JSON without the new fields still loads")
    func oldJSON() throws {
        let songs = try SongImporter.songs(fromJSON: Data(#"[{"title": "X", "sections": [{"name": "Verse 1", "lyrics": "a"}]}]"#.utf8))
        #expect(songs.first?.ccliNumber == "")
        #expect(songs.first?.themes == [])
    }
}

@Suite("Searching the song library")
struct SongSearchTests {
    let grace = SongRecord(title: "Amazing Grace", artist: "John Newton", sections: [
        SongSection(name: "Verse 1", lyrics: "Amazing grace how sweet the sound\nThat saved a wretch like me"),
        SongSection(name: "Verse 2", lyrics: "'Twas grace that taught my heart to fear"),
    ], ccliNumber: "22025")
    let great = SongRecord(title: "How Great Thou Art", artist: "Carl Boberg", sections: [
        SongSection(name: "Verse 1", lyrics: "O Lord my God when I in awesome wonder\nConsider all the worlds thy hands have made"),
    ], ccliNumber: "14181")
    let vision = SongRecord(title: "Be Thou My Vision", artist: "Dallan Forgaill", sections: [
        SongSection(name: "Verse 1", lyrics: "Be thou my vision O Lord of my heart"),
    ])

    var index: SongSearchIndex { SongSearchIndex([grace, great, vision].map { SongSearchEntry(record: $0) }) }

    func top(_ query: String) -> UUID? { index.search(query).first?.id }

    @Test("Title, with typos and unfinished words")
    func titles() {
        #expect(top("amazing grace") == grace.id)
        #expect(top("amazng grase") == grace.id)
        #expect(top("amaz") == grace.id)
        #expect(top("how gre") == great.id)
        #expect(top("be thou") == vision.id)
    }

    @Test("First line and any lyric line, with the matching line shown")
    func lyrics() throws {
        let line = try #require(index.search("wretch like me").first)
        #expect(line.id == grace.id)
        #expect(line.matchedLine == "That saved a wretch like me")
        #expect(top("o lord my god when i") == great.id)
        #expect(index.search("lord of my heart").first?.field == .lyrics || index.search("lord of my heart").first?.field == .firstLine)
    }

    @Test("Author and CCLI number")
    func authorAndNumber() {
        #expect(top("newton") == grace.id)
        #expect(top("boberg") == great.id)
        #expect(top("22025") == grace.id)
        #expect(index.search("22025").first?.field == .number)
    }

    @Test("Nothing for unrelated words")
    func noMatch() {
        #expect(index.search("pizza delivery").isEmpty)
        #expect(index.search("").isEmpty)
    }
}
