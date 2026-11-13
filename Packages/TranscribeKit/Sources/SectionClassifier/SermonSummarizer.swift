import Foundation
import FoundationModels
import TranscribeCore

public struct SermonSummary: Sendable, Equatable {
    public var title: String
    public var keyPoints: [String]
    public var takeaway: String

    public init(title: String, keyPoints: [String], takeaway: String) {
        self.title = title
        self.keyPoints = keyPoints
        self.takeaway = takeaway
    }
}

@Generable(description: "A summary of a sermon.")
struct GeneratedSermonSummary {
    @Guide(description: "A short descriptive title for the sermon, 2 to 6 words.")
    var title: String

    @Guide(description: "The sermon's main points, each one clear sentence.", .count(3...6))
    var keyPoints: [String]

    @Guide(description: "One sentence: the main thing listeners were asked to remember or do.")
    var takeaway: String
}

@Generable(description: "Notes on part of a sermon.")
struct GeneratedSermonNotes {
    @Guide(description: "The main points made in this part, each one sentence.", .count(1...4))
    var points: [String]
}

public enum SummaryError: LocalizedError, Sendable {
    case unavailable(String)
    case noSermon

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason): reason
        case .noSermon: "There's no sermon text to summarize yet."
        }
    }
}

/// Summarizes a sermon on-device. Long sermons are summarized in parts first, because the
/// on-device model has a limited context window.
public actor SermonSummarizer {
    static let chunkWords = 1200

    public init() {}

    public func summarize(_ sermon: String) async throws -> SermonSummary {
        if case .unavailable(let reason) = IntelligenceStatus.current { throw SummaryError.unavailable(reason) }
        let words = sermon.split(whereSeparator: \.isWhitespace)
        guard words.count >= 40 else { throw SummaryError.noSermon }

        var material = sermon
        if words.count > Self.chunkWords {
            var notes: [String] = []
            for start in stride(from: 0, to: words.count, by: Self.chunkWords) {
                let chunk = words[start..<min(start + Self.chunkWords, words.count)].joined(separator: " ")
                let session = LanguageModelSession(instructions: "You take concise notes on sermon transcripts. The text comes from speech recognition and may contain errors.")
                let response = try await session.respond(to: "Part of a sermon:\n\(chunk)", generating: GeneratedSermonNotes.self)
                notes += response.content.points
            }
            material = "Notes taken on the sermon, in order:\n- " + notes.joined(separator: "\n- ")
        }

        do {
            let session = LanguageModelSession(instructions: "You summarize sermons faithfully for a church's records. Don't add ideas that aren't in the sermon.")
            let response = try await session.respond(to: "Summarize this sermon.\n\n\(material)", generating: GeneratedSermonSummary.self, options: GenerationOptions(temperature: 0.2))
            let output = response.content
            return SermonSummary(title: output.title, keyPoints: output.keyPoints, takeaway: output.takeaway)
        } catch LanguageModelSession.GenerationError.refusal, LanguageModelSession.GenerationError.guardrailViolation {
            // Religious content sometimes trips the default guardrails. Summarizing the user's own
            // transcript is a content transformation, which the permissive mode is meant for; it
            // only produces plain text, so ask for a simple layout and parse it.
            return try await Self.summarizePermissively(material)
        }
    }

    static func summarizePermissively(_ material: String) async throws -> SermonSummary {
        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        let session = LanguageModelSession(model: model, instructions: "You summarize sermon transcripts faithfully for a church's records. Don't add ideas that aren't in the text.")
        let prompt = """
            Read the sermon below, then write a summary of it in your own words. Use exactly this layout, \
            with three to five points:

            TITLE: Short descriptive title
            - First main point, in one sentence.
            - Second main point, in one sentence.
            - Third main point, in one sentence.
            TAKEAWAY: The one thing listeners were asked to remember or do, in one sentence.

            Sermon:
            \(material)
            """
        let text = try await session.respond(to: prompt, options: GenerationOptions(temperature: 0.3)).content
        return parse(text)
    }

    /// Reads the TITLE / bullet / TAKEAWAY layout, tolerating markdown decoration.
    static func parse(_ text: String) -> SermonSummary {
        var title = ""
        var points: [String] = []
        var takeaway = ""
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "**", with: "")
            let upper = line.uppercased()
            if upper.hasPrefix("TITLE:") {
                title = String(line.dropFirst(6))
            } else if upper.hasPrefix("TAKEAWAY:") {
                takeaway = String(line.dropFirst(9))
            } else if let first = line.first, "-•*".contains(first) {
                points.append(String(line.dropFirst()))
            } else if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty {
                points.append(String(line[line.index(after: dot)...]))
            }
        }
        let clean = { (s: String) in s.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"“”"))) }
        return SermonSummary(title: clean(title), keyPoints: points.map(clean).filter { !$0.isEmpty }, takeaway: clean(takeaway))
    }
}
