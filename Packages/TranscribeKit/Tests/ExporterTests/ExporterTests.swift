import AppKit
import Foundation
import Testing
@testable import Exporter

private let sample = ExportDocument(
    title: "Sunday Service",
    date: Date(timeIntervalSince1970: 1_800_000_000),
    blocks: [
        .header(title: "Worship", subtitle: ""),
        .song(time: 12, title: "Amazing Grace", artist: "John Newton", sections: [("Verse 1", "Amazing grace! How sweet the sound\nThat saved a wretch like me!")]),
        .header(title: "Sermon", subtitle: "Faith in the Waiting"),
        .paragraph(time: 600, text: "Turn with me to John 3:16."),
        .verse(time: 605, reference: "John 3:16", version: "KJV", confidence: 0.92, text: "For God so loved the world…", spoken: "for God so love the world"),
    ],
    summary: ExportSummary(title: "Faith in the Waiting", keyPoints: ["God keeps His promises.", "Waiting is active trust."], takeaway: "Trust God today.", scriptures: ["John 3:16"])
)

@Suite("Export")
struct ExporterTests {
    @Test("Markdown keeps headers, songs, verses and the summary")
    func markdown() {
        let md = Exporter.markdown(sample)
        #expect(md.hasPrefix("# Sunday Service"))
        #expect(md.contains("## Worship"))
        #expect(md.contains("## Sermon: Faith in the Waiting"))
        #expect(md.contains("### 🎵 Song: Amazing Grace — John Newton"))
        #expect(md.contains("*Verse 1*"))
        #expect(md.contains("> **📖 John 3:16** — KJV, 92%"))
        #expect(md.contains("`10:00` Turn with me to John 3:16."))
        #expect(md.contains("## Sermon Summary: Faith in the Waiting"))
        #expect(md.contains("**Scriptures referenced:** John 3:16"))
    }

    @Test("Plain text keeps the same structure")
    func plainText() {
        let text = Exporter.plainText(sample)
        #expect(text.contains("SERMON: FAITH IN THE WAITING"))
        #expect(text.contains("♪ SONG: Amazing Grace — John Newton"))
        #expect(text.contains("┃ John 3:16 — KJV, 92%"))
        #expect(text.contains("[10:00] Turn with me"))
    }

    @Test("Timestamps can be left out")
    func noTimestamps() {
        var doc = sample
        doc.includeTimestamps = false
        #expect(!Exporter.markdown(doc).contains("`10:00`"))
    }

    @Test("PDF is a real PDF")
    func pdf() throws {
        let data = try Exporter.data(for: sample, as: .pdf)
        #expect(String(decoding: data.prefix(5), as: UTF8.self) == "%PDF-")
        #expect(data.count > 1000)
    }

    @Test("PDF paginates long transcripts")
    func longPDF() throws {
        var doc = sample
        doc.blocks = (0..<400).map { .paragraph(time: Double($0) * 10, text: "This is paragraph \($0) of a long sermon transcript that goes on for many pages.") }
        let data = try Exporter.pdf(doc)
        let pages = CGPDFDocument(CGDataProvider(data: data as CFData)!)?.numberOfPages ?? 0
        #expect(pages > 3)
    }

    @Test("Word export is a .docx (zip) containing the text")
    func docx() throws {
        let data = try Exporter.data(for: sample, as: .docx)
        #expect(data.prefix(2) == Data("PK".utf8))
        // Round-trip through AppKit to check the content survived.
        let back = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil)
        #expect(back.string.contains("Sermon: Faith in the Waiting"))
        #expect(back.string.contains("John 3:16 — KJV, 92%"))
    }
}
