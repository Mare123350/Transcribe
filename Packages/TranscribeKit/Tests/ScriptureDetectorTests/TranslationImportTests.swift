import Foundation
import Testing
@testable import ScriptureDetector

private func temporaryFile(_ name: String, _ contents: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: "import-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: name)
    try contents.write(to: url, atomically: true, encoding: .utf8)
    return url
}

private func text(_ parsed: ParsedTranslation, _ book: String, _ chapter: Int, _ verse: Int) -> String? {
    parsed.verses.first { $0.book == book && $0.chapter == chapter && $0.verse == verse }?.text
}

@Suite("Importing licensed translations")
struct TranslationImportTests {
    @Test("OSIS: container and milestone verses, notes and headings skipped, metadata read")
    func osis() throws {
        let url = try temporaryFile("sample.xml", """
            <?xml version="1.0" encoding="UTF-8"?>
            <osis xmlns="http://www.bibletechnologies.net/2003/OSIS/namespace">
              <osisText osisIDWork="TST" xml:lang="en">
                <header><work osisWork="TST"><title>Test Version</title><rights>Licensed to Grace Church</rights></work></header>
                <div type="book" osisID="John">
                  <chapter osisID="John.3">
                    <title type="section">For God So Loved the World</title>
                    <verse osisID="John.3.16">For God so loved the world,<note type="study">Greek: kosmos</note> that he gave his only Son.</verse>
                    <verse sID="John.3.17" osisID="John.3.17"/>For God did not send his Son <w lemma="x">to condemn</w> the world.<verse eID="John.3.17"/>
                  </chapter>
                </div>
                <div type="book" osisID="Tob"><chapter osisID="Tob.1"><verse osisID="Tob.1.1">Apocryphal text.</verse></chapter></div>
              </osisText>
            </osis>
            """)
        #expect(try TranslationImporter.detectFormat(of: url) == .osis)
        let parsed = try TranslationImporter.parse(url)
        #expect(parsed.abbreviation == "TST")
        #expect(parsed.name == "Test Version")
        #expect(parsed.license == "Licensed to Grace Church")
        #expect(text(parsed, "JHN", 3, 16) == "For God so loved the world, that he gave his only Son.")
        #expect(text(parsed, "JHN", 3, 17) == "For God did not send his Son to condemn the world.")
        #expect(parsed.verses.count == 2)
        #expect(parsed.warnings.contains { $0.contains("Tob") })
    }

    @Test("USFM: footnotes, word attributes, headings and bridged verses")
    func usfm() throws {
        let url = try temporaryFile("43JHNTST.usfm", #"""
            \id JHN Test Version
            \h John
            \mt1 The Gospel of John
            \c 3
            \s1 For God So Loved the World
            \p
            \v 16 For God so loved \w the world|strong="G2889"\w* that he gave\f + \fr 3:16 \ft Or his only begotten Son\f* his one and only Son,
            \q1 that whoever believes in him shall not perish.
            \v 17-18 For God did not send his Son into the world to condemn the world.
            \c 4
            \p
            \v 1 Now Jesus learned \wj that the Pharisees\wj* had heard.
            """#)
        #expect(try TranslationImporter.detectFormat(of: url) == .usfm)
        let parsed = try TranslationImporter.parse(url)
        #expect(text(parsed, "JHN", 3, 16) == "For God so loved the world that he gave his one and only Son, that whoever believes in him shall not perish.")
        #expect(text(parsed, "JHN", 3, 17) == "For God did not send his Son into the world to condemn the world.")
        #expect(text(parsed, "JHN", 4, 1) == "Now Jesus learned that the Pharisees had heard.")
        #expect(parsed.verses.count == 3)
    }

    @Test("USFM: a folder of one book per file")
    func usfmFolder() throws {
        let john = try temporaryFile("43JHN.usfm", "\\id JHN\n\\c 1\n\\p\n\\v 1 In the beginning was the Word.\n")
        try "\\id GEN\n\\c 1\n\\p\n\\v 1 In the beginning God created.\n".write(to: john.deletingLastPathComponent().appending(path: "01GEN.usfm"), atomically: true, encoding: .utf8)
        let parsed = try TranslationImporter.parse([john.deletingLastPathComponent()])
        #expect(parsed.bookCount == 2)
        #expect(parsed.hasOldTestament && parsed.hasNewTestament)
    }

    @Test("USX: verse milestones, notes and section headings skipped")
    func usx() throws {
        let url = try temporaryFile("JHN.usx", """
            <?xml version="1.0" encoding="utf-8"?>
            <usx version="3.0">
              <book code="JHN" style="id">Test Version</book>
              <para style="h">John</para>
              <chapter number="3" style="c" sid="JHN 3"/>
              <para style="s1">For God So Loved the World</para>
              <para style="p"><verse number="16" style="v" sid="JHN 3:16"/>For God so loved the world<note caller="+" style="f"><char style="ft">Or kosmos</char></note> that he gave his Son.<verse eid="JHN 3:16"/>
              <verse number="17" style="v" sid="JHN 3:17"/>For God did not send his Son<verse eid="JHN 3:17"/></para>
              <para style="q1"><verse number="18" style="v"/>to condemn the world.</para>
              <chapter eid="JHN 3"/>
            </usx>
            """)
        #expect(try TranslationImporter.detectFormat(of: url) == .usx)
        let parsed = try TranslationImporter.parse(url)
        #expect(text(parsed, "JHN", 3, 16) == "For God so loved the world that he gave his Son.")
        #expect(text(parsed, "JHN", 3, 17) == "For God did not send his Son")
        #expect(text(parsed, "JHN", 3, 18) == "to condemn the world.")
    }

    @Test("Zefania XML: books by number, notes skipped, metadata read")
    func zefania() throws {
        let url = try temporaryFile("zefania.xml", """
            <?xml version="1.0" encoding="utf-8"?>
            <XMLBIBLE biblename="Zefania Test Bible">
              <INFORMATION><title>Zefania Test Bible</title><identifier>ZTB</identifier><rights>Licensed copy</rights></INFORMATION>
              <BIBLEBOOK bnumber="43" bname="John">
                <CHAPTER cnumber="3">
                  <VERS vnumber="16">For God so loved the world, <NOTE>a note</NOTE>that he gave his Son.</VERS>
                </CHAPTER>
              </BIBLEBOOK>
              <BIBLEBOOK bnumber="19" bname="Psalms"><CHAPTER cnumber="23"><VERS vnumber="1">The LORD is my shepherd.</VERS></CHAPTER></BIBLEBOOK>
            </XMLBIBLE>
            """)
        #expect(try TranslationImporter.detectFormat(of: url) == .zefania)
        let parsed = try TranslationImporter.parse(url)
        #expect(parsed.abbreviation == "ZTB")
        #expect(parsed.name == "Zefania Test Bible")
        #expect(text(parsed, "JHN", 3, 16) == "For God so loved the world, that he gave his Son.")
        #expect(text(parsed, "PSA", 23, 1) == "The LORD is my shepherd.")
    }

    @Test("JSON: USFM codes and book names")
    func json() throws {
        let url = try temporaryFile("t.json", """
            {"abbreviation": "JTV", "name": "JSON Test Version", "verses": [
              {"book": "JHN", "chapter": 3, "verse": 16, "text": "For God so loved the world."},
              {"book": "1 Corinthians", "chapter": 13, "verse": 4, "text": "Love is patient."}
            ]}
            """)
        let parsed = try TranslationImporter.parse(url)
        #expect(parsed.abbreviation == "JTV")
        #expect(text(parsed, "1CO", 13, 4) == "Love is patient.")
    }

    @Test("Installing writes a translation the app can read")
    func install() throws {
        let url = try temporaryFile("43JHN.usfm", "\\id JHN\n\\c 3\n\\p\n\\v 16 For God so loved the world.\n\\v 17 For God did not send his Son.\n")
        let parsed = try TranslationImporter.parse(url)
        let directory = url.deletingLastPathComponent().appending(path: "installed")
        let installed = try TranslationImporter.install(parsed, abbreviation: "NIV", name: "New International Version", license: "Licensed to Grace Church", into: directory, existingIDs: ["kjv"])
        let translation = try BibleTranslation(url: installed, isBundled: false)
        #expect(translation.info.abbreviation == "NIV")
        #expect(translation.text(of: BibleReference(book: "JHN", chapter: 3, verseStart: 16, verseEnd: 17)) == "For God so loved the world. For God did not send his Son.")
        #expect(throws: TranslationError.self) {
            try TranslationImporter.install(parsed, abbreviation: "KJV", name: "", license: "", into: directory, existingIDs: ["kjv"])
        }
    }

    @Test("Problems are reported clearly")
    func errors() throws {
        let unknown = try temporaryFile("notes.txt", "Just some sermon notes, not a Bible.")
        #expect(message { try TranslationImporter.parse(unknown) }.contains("isn't a Bible format"))

        let broken = try temporaryFile("broken.xml", "<?xml version=\"1.0\"?>\n<XMLBIBLE>\n<BIBLEBOOK bnumber=\"43\">\n<CHAPTER cnumber=\"3\">\n<VERS vnumber=\"16\">text</CHAPTER>")
        let brokenMessage = message { try TranslationImporter.parse(broken) }
        #expect(brokenMessage.contains("Zefania XML") && brokenMessage.contains("line"))

        let badBook = try temporaryFile("bad.usfm", "\\id XYZ\n\\c 1\n\\v 1 Text\n")
        #expect(message { try TranslationImporter.parse(badBook) }.contains("unknown book code “XYZ”"))

        let empty = try temporaryFile("empty.usfm", "\\id JHN\n\\c 1\n")
        #expect(message { try TranslationImporter.parse(empty) }.contains("no verses"))

        let badJSON = try temporaryFile("bad.json", #"{"abbreviation": "X", "verses": []}"#)
        #expect(message { try TranslationImporter.parse(badJSON) }.contains("“name” field is missing"))

        let books = try temporaryFile("books.json", #"{"abbreviation": "X", "name": "X", "verses": [{"book": "Hezekiah", "chapter": 1, "verse": 1, "text": "x"}]}"#)
        #expect(message { try TranslationImporter.parse(books) }.contains("Hezekiah"))
    }

    private func message(_ body: () throws -> Any) -> String {
        do {
            _ = try body()
            return "no error"
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }
}
