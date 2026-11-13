import Foundation

/// A transcript ready to export, independent of how the app stores it.
public struct ExportDocument: Sendable {
    public var title: String
    public var date: Date
    public var blocks: [ExportBlock]
    public var summary: ExportSummary?
    public var includeTimestamps: Bool

    public init(title: String, date: Date, blocks: [ExportBlock], summary: ExportSummary? = nil, includeTimestamps: Bool = true) {
        self.title = title
        self.date = date
        self.blocks = blocks
        self.summary = summary
        self.includeTimestamps = includeTimestamps
    }

    var dateLine: String {
        date.formatted(date: .complete, time: .shortened)
    }
}

public enum ExportBlock: Sendable, Equatable {
    case header(title: String, subtitle: String)
    case paragraph(time: TimeInterval?, text: String)
    case song(time: TimeInterval?, title: String, artist: String, sections: [(name: String, lyrics: String)])
    case verse(time: TimeInterval?, reference: String, version: String, confidence: Double?, text: String, spoken: String)

    public static func == (lhs: ExportBlock, rhs: ExportBlock) -> Bool {
        switch (lhs, rhs) {
        case let (.header(a, b), .header(c, d)): a == c && b == d
        case let (.paragraph(a, b), .paragraph(c, d)): a == c && b == d
        case let (.song(t1, a, b, s1), .song(t2, c, d, s2)):
            t1 == t2 && a == c && b == d && s1.map(\.name) == s2.map(\.name) && s1.map(\.lyrics) == s2.map(\.lyrics)
        case let (.verse(t1, a, b, c, d, e), .verse(t2, f, g, h, i, j)): t1 == t2 && a == f && b == g && c == h && d == i && e == j
        default: false
        }
    }

    /// "Sermon: Faith in the Waiting"
    static func headerText(_ title: String, _ subtitle: String) -> String {
        subtitle.isEmpty ? title : "\(title): \(subtitle)"
    }

    /// "KJV, 92%", "NIV", or "" when unknown.
    static func versionText(_ version: String, _ confidence: Double?) -> String {
        guard !version.isEmpty else { return "" }
        guard let confidence else { return version }
        return "\(version), \(Int((confidence * 100).rounded()))%"
    }
}

public struct ExportSummary: Sendable, Equatable {
    public var title: String
    public var keyPoints: [String]
    public var takeaway: String
    public var scriptures: [String]

    public init(title: String, keyPoints: [String], takeaway: String, scriptures: [String]) {
        self.title = title
        self.keyPoints = keyPoints
        self.takeaway = takeaway
        self.scriptures = scriptures
    }
}

public enum ExportFormat: String, CaseIterable, Sendable, Identifiable {
    case markdown, pdf, docx, plainText

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .markdown: "Markdown"
        case .pdf: "PDF"
        case .docx: "Word Document"
        case .plainText: "Plain Text"
        }
    }

    public var fileExtension: String {
        switch self {
        case .markdown: "md"
        case .pdf: "pdf"
        case .docx: "docx"
        case .plainText: "txt"
        }
    }
}

func clock(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds))
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}
