import AppKit
import Exporter
import Foundation
import SectionClassifier
import UniformTypeIdentifiers

/// Turns a session into an export document, optionally with an on-device sermon summary.
@MainActor
enum ExportService {
    /// Consecutive transcript lines within this gap are joined into one paragraph.
    static let paragraphGap: TimeInterval = 20
    static let paragraphWords = 140

    static func document(for session: Session, includeTimestamps: Bool, summary: ExportSummary?) -> ExportDocument {
        var blocks: [ExportBlock] = []
        var paragraph: (time: TimeInterval, text: String, end: TimeInterval)?

        func flush() {
            if let p = paragraph { blocks.append(.paragraph(time: p.time, text: p.text)) }
            paragraph = nil
        }

        for item in session.orderedItems {
            switch item.kind {
            case .segment:
                guard item.parentItemID == nil else { continue } // shown as the song's lyrics instead
                if var p = paragraph, item.timestamp - p.end < paragraphGap, p.text.split(separator: " ").count < paragraphWords {
                    p.text += " " + item.text
                    p.end = item.endTimestamp
                    paragraph = p
                } else {
                    flush()
                    paragraph = (item.timestamp, item.text, item.endTimestamp)
                }
            case .header:
                flush()
                blocks.append(.header(title: item.title.isEmpty ? (item.sectionType?.title ?? "Section") : item.title, subtitle: item.subtitle))
            case .song:
                flush()
                blocks.append(.song(time: item.timestamp, title: item.title, artist: item.artist, sections: item.lyricSections.map { ($0.name, $0.lyrics) }))
            case .verse:
                flush()
                let confidence: Double? = item.verseSource == .manual || item.versionNamedBySpeaker || item.versionScores.isEmpty ? nil : item.confidence
                let version = item.requestedVersion.isEmpty ? item.versionAbbreviation : "\(item.versionAbbreviation); \(item.requestedVersion) requested"
                let text = item.verseCopyright.isEmpty ? item.verseText : "\(item.verseText)\n\(item.verseCopyright)"
                blocks.append(.verse(time: item.timestamp, reference: item.reference, version: version, confidence: confidence, text: text, spoken: item.spokenText))
            }
        }
        flush()
        return ExportDocument(title: session.title, date: session.createdAt, blocks: blocks, summary: summary, includeTimestamps: includeTimestamps)
    }

    /// The sermon's words: from the first Sermon header to the next header, or the whole spoken
    /// transcript if there's no sermon header.
    static func sermonText(in session: Session) -> String {
        let items = session.orderedItems
        var inSermon = false
        var hasSermonHeader = false
        var words: [String] = []
        for item in items {
            if item.kind == .header {
                inSermon = item.sectionType == .sermon
                hasSermonHeader = hasSermonHeader || inSermon
            } else if item.kind == .segment, item.parentItemID == nil, inSermon {
                words.append(item.text)
            }
        }
        if hasSermonHeader { return words.joined(separator: " ") }
        return items.filter { $0.kind == .segment && $0.parentItemID == nil }.map(\.text).joined(separator: " ")
    }

    static func scriptures(in session: Session) -> [String] {
        var seen = Set<String>()
        return session.orderedItems.filter { $0.kind == .verse }.compactMap { item in
            let label = item.versionAbbreviation.isEmpty ? item.reference : "\(item.reference) (\(item.versionAbbreviation))"
            return seen.insert(label).inserted ? label : nil
        }
    }

    static func summary(for session: Session) async throws -> ExportSummary {
        let result = try await SermonSummarizer().summarize(sermonText(in: session))
        return ExportSummary(title: result.title, keyPoints: result.keyPoints, takeaway: result.takeaway, scriptures: scriptures(in: session))
    }

    /// Asks where to save, then writes the file.
    static func save(_ data: Data, format: ExportFormat, suggestedName: String) throws -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName.replacingOccurrences(of: "/", with: "-") + "." + format.fileExtension
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .data]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        try data.write(to: url, options: .atomic)
        return url
    }
}
