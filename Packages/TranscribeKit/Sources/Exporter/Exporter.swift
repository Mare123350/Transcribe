import AppKit
import CoreText
import Foundation

public enum ExportError: LocalizedError, Sendable {
    case renderFailed(String)

    public var errorDescription: String? {
        switch self {
        case .renderFailed(let format): "Couldn't create the \(format) file."
        }
    }
}

public enum Exporter {
    public static func data(for document: ExportDocument, as format: ExportFormat) throws -> Data {
        switch format {
        case .markdown: Data(markdown(document).utf8)
        case .plainText: Data(plainText(document).utf8)
        case .pdf: try pdf(document)
        case .docx: try docx(document)
        }
    }

    // MARK: Markdown

    public static func markdown(_ doc: ExportDocument) -> String {
        var out = "# \(doc.title)\n\n_\(doc.dateLine)_\n"
        if let summary = doc.summary { out += "\n" + summaryMarkdown(summary) }
        for block in doc.blocks {
            out += "\n"
            switch block {
            case let .header(title, subtitle):
                out += "## \(ExportBlock.headerText(title, subtitle))\n"
            case let .paragraph(time, text):
                out += (doc.includeTimestamps ? time.map { "`\(clock($0))` " } ?? "" : "") + text + "\n"
            case let .song(time, title, artist, sections):
                out += "### 🎵 Song: \(title)" + (artist.isEmpty ? "" : " — \(artist)") + (doc.includeTimestamps ? time.map { " `\(clock($0))`" } ?? "" : "") + "\n"
                for section in sections {
                    out += "\n"
                    if !section.name.isEmpty { out += "*\(section.name)*  \n" }
                    out += section.lyrics.split(separator: "\n", omittingEmptySubsequences: false).joined(separator: "  \n") + "\n"
                }
            case let .verse(time, reference, version, confidence, text, spoken):
                let versionText = ExportBlock.versionText(version, confidence)
                out += "> **📖 \(reference)**" + (versionText.isEmpty ? "" : " — \(versionText)") + (doc.includeTimestamps ? time.map { " `\(clock($0))`" } ?? "" : "") + "\n>\n"
                out += "> " + (text.isEmpty ? "_\(spoken)_" : text) + "\n"
                if !spoken.isEmpty && !text.isEmpty {
                    out += ">\n> <details><summary>Spoken</summary>\(spoken)</details>\n"
                }
            }
        }
        return out
    }

    private static func summaryMarkdown(_ summary: ExportSummary) -> String {
        var out = "## Sermon Summary: \(summary.title)\n\n"
        out += summary.keyPoints.map { "- \($0)" }.joined(separator: "\n") + "\n"
        if !summary.takeaway.isEmpty { out += "\n**Takeaway:** \(summary.takeaway)\n" }
        if !summary.scriptures.isEmpty { out += "\n**Scriptures referenced:** " + summary.scriptures.joined(separator: "; ") + "\n" }
        return out + "\n---\n"
    }

    // MARK: Plain text

    public static func plainText(_ doc: ExportDocument) -> String {
        var out = "\(doc.title)\n\(doc.dateLine)\n"
        if let summary = doc.summary {
            out += "\nSERMON SUMMARY: \(summary.title.uppercased())\n"
            out += summary.keyPoints.map { "  • \($0)" }.joined(separator: "\n") + "\n"
            if !summary.takeaway.isEmpty { out += "  Takeaway: \(summary.takeaway)\n" }
            if !summary.scriptures.isEmpty { out += "  Scriptures referenced: " + summary.scriptures.joined(separator: "; ") + "\n" }
        }
        for block in doc.blocks {
            switch block {
            case let .header(title, subtitle):
                let text = ExportBlock.headerText(title, subtitle).uppercased()
                out += "\n\n\(text)\n" + String(repeating: "=", count: text.count) + "\n"
            case let .paragraph(time, text):
                out += "\n" + (doc.includeTimestamps ? time.map { "[\(clock($0))] " } ?? "" : "") + text
            case let .song(_, title, artist, sections):
                out += "\n\n♪ SONG: \(title)" + (artist.isEmpty ? "" : " — \(artist)") + "\n"
                for section in sections {
                    if !section.name.isEmpty { out += "\n  (\(section.name))\n" }
                    out += section.lyrics.split(separator: "\n").map { "  \($0)" }.joined(separator: "\n") + "\n"
                }
            case let .verse(_, reference, version, confidence, text, spoken):
                let versionText = ExportBlock.versionText(version, confidence)
                out += "\n\n  ┃ \(reference)" + (versionText.isEmpty ? "" : " — \(versionText)") + "\n"
                out += "  ┃ " + (text.isEmpty ? spoken : text) + "\n"
            }
        }
        return out + "\n"
    }

    // MARK: Rich text (PDF and Word)

    static func attributed(_ doc: ExportDocument) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let body = NSFont.systemFont(ofSize: 11)
        let serif = NSFont(name: "Georgia", size: 11.5) ?? body
        let secondary = NSColor(white: 0.4, alpha: 1)

        func paragraph(spacingBefore: CGFloat = 0, spacingAfter: CGFloat = 6, indent: CGFloat = 0) -> NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacingBefore = spacingBefore
            style.paragraphSpacing = spacingAfter
            style.firstLineHeadIndent = indent
            style.headIndent = indent
            style.lineHeightMultiple = 1.15
            return style
        }
        func add(_ text: String, _ font: NSFont, color: NSColor = .black, style: NSParagraphStyle) {
            result.append(NSAttributedString(string: text + "\n", attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style]))
        }

        add(doc.title, .boldSystemFont(ofSize: 22), style: paragraph(spacingAfter: 2))
        add(doc.dateLine, body, color: secondary, style: paragraph(spacingAfter: 14))

        if let summary = doc.summary {
            add("Sermon Summary: \(summary.title)", .boldSystemFont(ofSize: 15), style: paragraph(spacingBefore: 4))
            for point in summary.keyPoints { add("•  \(point)", body, style: paragraph(spacingAfter: 3, indent: 12)) }
            if !summary.takeaway.isEmpty { add("Takeaway: \(summary.takeaway)", .boldSystemFont(ofSize: 11), style: paragraph(spacingBefore: 4)) }
            if !summary.scriptures.isEmpty { add("Scriptures referenced: " + summary.scriptures.joined(separator: "; "), body, color: secondary, style: paragraph(spacingAfter: 16)) }
        }

        for block in doc.blocks {
            switch block {
            case let .header(title, subtitle):
                add(ExportBlock.headerText(title, subtitle), .boldSystemFont(ofSize: 16), color: NSColor(red: 0.1, green: 0.25, blue: 0.55, alpha: 1), style: paragraph(spacingBefore: 14, spacingAfter: 6))
            case let .paragraph(time, text):
                let line = NSMutableAttributedString()
                if doc.includeTimestamps, let time {
                    line.append(NSAttributedString(string: clock(time) + "   ", attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular), .foregroundColor: secondary]))
                }
                line.append(NSAttributedString(string: text + "\n", attributes: [.font: body, .foregroundColor: NSColor.black]))
                line.addAttribute(.paragraphStyle, value: paragraph(), range: NSRange(location: 0, length: line.length))
                result.append(line)
            case let .song(_, title, artist, sections):
                let purple = NSColor(red: 0.45, green: 0.2, blue: 0.6, alpha: 1)
                add("♪ Song: \(title)" + (artist.isEmpty ? "" : " — \(artist)"), .boldSystemFont(ofSize: 12), color: purple, style: paragraph(spacingBefore: 6, spacingAfter: 4, indent: 14))
                for section in sections {
                    if !section.name.isEmpty { add(section.name.uppercased(), .boldSystemFont(ofSize: 8.5), color: purple, style: paragraph(spacingAfter: 1, indent: 14)) }
                    add(section.lyrics, body, style: paragraph(spacingAfter: 6, indent: 14))
                }
            case let .verse(_, reference, version, confidence, text, spoken):
                let orange = NSColor(red: 0.75, green: 0.4, blue: 0.0, alpha: 1)
                let versionText = ExportBlock.versionText(version, confidence)
                add("📖 \(reference)" + (versionText.isEmpty ? "" : " — \(versionText)"), .boldSystemFont(ofSize: 12), color: orange, style: paragraph(spacingBefore: 6, spacingAfter: 3, indent: 14))
                add(text.isEmpty ? spoken : text, serif, style: paragraph(spacingAfter: 8, indent: 14))
            }
        }
        return result
    }

    public static func docx(_ doc: ExportDocument) throws -> Data {
        let text = attributed(doc)
        do {
            return try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [
                .documentType: NSAttributedString.DocumentType.officeOpenXML,
                .title: doc.title,
            ])
        } catch {
            throw ExportError.renderFailed("Word")
        }
    }

    /// US Letter pages with 0.75" margins, laid out with Core Text.
    public static func pdf(_ doc: ExportDocument) throws -> Data {
        let text = attributed(doc)
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, [kCGPDFContextTitle as String: doc.title] as CFDictionary) else {
            throw ExportError.renderFailed("PDF")
        }
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let frameRect = mediaBox.insetBy(dx: 54, dy: 54)
        var position = 0
        var page = 1
        repeat {
            context.beginPDFPage(nil)
            let path = CGPath(rect: frameRect, transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: position, length: 0), path, nil)
            CTFrameDraw(frame, context)

            // Page number
            let number = NSAttributedString(string: "\(page)", attributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.gray])
            let line = CTLineCreateWithAttributedString(number)
            context.textPosition = CGPoint(x: mediaBox.midX - 4, y: 30)
            CTLineDraw(line, context)
            context.endPDFPage()

            let visible = CTFrameGetVisibleStringRange(frame)
            if visible.length == 0 { break }
            position += visible.length
            page += 1
        } while position < text.length
        context.closePDF()
        return data as Data
    }
}
