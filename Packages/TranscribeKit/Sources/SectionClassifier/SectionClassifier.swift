import Foundation
import FoundationModels
import TranscribeCore

/// Parts of a church service.
public enum ServiceSectionKind: String, CaseIterable, Sendable {
    case welcome, worship, prayer, announcements, scriptureReading, sermon, offering, altarCall, closing
}

public struct SectionDecision: Sendable, Equatable {
    public enum Source: Sendable { case model, keywords }
    public let kind: ServiceSectionKind
    public let suggestedTitle: String
    public let confidence: Double
    public let source: Source
}

/// Whether the on-device model can be used, and if not, why.
public enum IntelligenceStatus: Sendable, Equatable {
    case available
    case unavailable(String)

    public static var current: IntelligenceStatus {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailable("Apple Intelligence is turned off. Turn it on in System Settings › Apple Intelligence & Siri for smarter headers and summaries.")
        case .unavailable(.deviceNotEligible):
            return .unavailable("This Mac doesn't support Apple Intelligence. Headers use keyword matching instead.")
        case .unavailable(.modelNotReady):
            return .unavailable("The Apple Intelligence model is still downloading. Headers use keyword matching until it's ready.")
        case .unavailable:
            return .unavailable("Apple Intelligence isn't available. Headers use keyword matching instead.")
        }
    }

    public var isAvailable: Bool { self == .available }
}

// MARK: - Generable output

@Generable
enum GeneratedSectionType: String {
    case welcome, worship, prayer, announcements, scriptureReading, sermon, offering, altarCall, closing
}

@Generable(description: "Which part of a church service a stretch of transcript belongs to.")
struct SectionClassification {
    @Guide(description: "The part of the service this text belongs to.")
    var sectionType: GeneratedSectionType

    @Guide(description: "A short header describing this text, 1 to 5 words, based only on what the text says.")
    var suggestedTitle: String

    @Guide(description: "How sure you are, from 0 to 1.", .range(0.0...1.0))
    var confidence: Double
}

@Generable(description: "A title for a sermon.")
struct SermonTitle {
    @Guide(description: "A short descriptive sermon title of 2 to 6 words, based on the sermon's main theme.")
    var title: String
}

// MARK: - Classifier

/// Labels chunks of finalized transcript with the part of the service they belong to.
/// Uses the on-device Foundation Models when available; otherwise keyword matching.
public actor SectionClassifier {
    private static let instructions = """
        You label one stretch of a live Christian church service transcript. It comes from speech \
        recognition and may contain mistakes. Decide from this text alone which part of the service it is:
        - welcome: greeting the congregation or welcoming visitors.
        - worship: singing or leading songs.
        - prayer: someone talking to God, e.g. "Father, we thank you… amen".
        - announcements: notices about upcoming events, meetings, schedules, or sign-ups.
        - scriptureReading: reading a Bible passage aloud.
        - sermon: preaching or teaching about God, faith, or the Bible, explaining or applying it.
        - offering: asking for or receiving tithes, offerings, or money.
        - altarCall: inviting people to respond to God, give their life to Jesus, or come forward for prayer.
        - closing: a blessing or benediction, dismissing the congregation.

        """

    public init() {}

    /// The last model error, for diagnostics.
    public private(set) var lastError: String?

    public var status: IntelligenceStatus { IntelligenceStatus.current }

    public func classify(_ text: String, previous: ServiceSectionKind?) async -> SectionDecision {
        guard IntelligenceStatus.current.isAvailable else { return KeywordSectionClassifier.classify(text) }
        let session = LanguageModelSession(instructions: Self.instructions)
        let prompt = "Transcript:\n\(text)"
        do {
            let response = try await session.respond(to: prompt, generating: SectionClassification.self, options: GenerationOptions(temperature: 0.1))
            let output = response.content
            guard let kind = ServiceSectionKind(rawValue: output.sectionType.rawValue) else { return KeywordSectionClassifier.classify(text) }
            return SectionDecision(kind: kind, suggestedTitle: output.suggestedTitle, confidence: min(max(output.confidence, 0), 1), source: .model)
        } catch {
            // Guardrails, context limits, or the model becoming unavailable: fall back quietly.
            return KeywordSectionClassifier.classify(text)
        }
    }

    /// A short sermon title from the opening of the sermon, e.g. "Faith in the Waiting".
    public func sermonTitle(for text: String) async -> String? {
        guard IntelligenceStatus.current.isAvailable else { return nil }
        let session = LanguageModelSession(instructions: "You write short, descriptive titles for sermons from their transcripts.")
        let excerpt = TextNormalizer.tokens(text).count > 900 ? String(text.prefix(5000)) : text
        do {
            let response = try await session.respond(to: "Sermon transcript:\n\(excerpt)", generating: SermonTitle.self, options: GenerationOptions(temperature: 0.3))
            let title = response.content.title.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”' ").union(.whitespacesAndNewlines))
            return title.isEmpty ? nil : title
        } catch {
            lastError = String(describing: error)
            // Fall back to plain text with the permissive guardrails (see SermonSummarizer).
            let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
            let fallback = LanguageModelSession(model: model, instructions: "You write short, descriptive titles for sermons from their transcripts.")
            let prompt = "Reply with only a title of 2 to 6 words for this sermon, with no quotation marks.\n\nSermon:\n\(excerpt)"
            guard let text = try? await fallback.respond(to: prompt, options: GenerationOptions(temperature: 0.3)).content else { return nil }
            let title = text.components(separatedBy: .newlines).first?
                .replacingOccurrences(of: "Title:", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'*# ").union(.whitespaces)) ?? ""
            return title.isEmpty || title.split(separator: " ").count > 10 ? nil : title
        }
    }
}

/// Fallback when Apple Intelligence is off: counts telltale phrases for each section.
public enum KeywordSectionClassifier {
    static let cues: [ServiceSectionKind: [String]] = [
        .welcome: ["welcome", "good morning", "good evening", "glad you're here", "glad you are here", "first time", "visitors", "visiting", "guests", "great to see"],
        .worship: ["let's sing", "lets sing", "sing together", "stand and sing", "let's worship", "lets worship", "lift your hands", "lift your voice", "make a joyful noise"],
        .prayer: ["let us pray", "let's pray", "lets pray", "bow your heads", "bow our heads", "heavenly father", "dear lord", "in jesus name", "in jesus' name", "we pray", "lord we thank you", "father we thank you", "amen"],
        .announcements: ["announcement", "this week", "next sunday", "sign up", "signup", "register", "meeting", "bulletin", "youth group", "small group", "potluck", "picnic", "volunteer", "calendar", "on saturday", "on wednesday"],
        .scriptureReading: ["turn with me", "turn to", "our reading", "scripture reading", "the word of the lord", "reading from", "open your bibles", "read with me", "thanks be to god"],
        .sermon: ["today i want to", "this morning i want", "my message", "the sermon", "first point", "second point", "the text says", "what this means", "let me tell you", "i want you to see", "listen church"],
        .offering: ["offering", "tithe", "tithes", "giving", "give generously", "generosity", "envelope", "text to give", "online giving", "cheerful giver", "ushers"],
        .altarCall: ["come forward", "altar", "give your life", "receive christ", "accept jesus", "raise your hand", "every head bowed", "make a decision", "if you don't know jesus", "pray this prayer"],
        .closing: ["benediction", "go in peace", "you are dismissed", "have a great week", "see you next week", "the lord bless you and keep you", "may the lord bless you", "closing prayer"],
    ]

    public static func classify(_ text: String) -> SectionDecision {
        let normalized = " " + TextNormalizer.tokens(text.replacingOccurrences(of: "'", with: "")).joined(separator: " ") + " "
        var best: (ServiceSectionKind, Int) = (.sermon, 0)
        for kind in ServiceSectionKind.allCases {
            let hits = (cues[kind] ?? []).reduce(0) { count, phrase in
                let cue = " " + TextNormalizer.tokens(phrase.replacingOccurrences(of: "'", with: "")).joined(separator: " ") + " "
                return count + normalized.components(separatedBy: cue).count - 1
            }
            if hits > best.1 { best = (kind, hits) }
        }
        // No cues: long unbroken speech is most often preaching, but say so only weakly.
        let confidence = best.1 == 0 ? 0.3 : min(0.9, 0.45 + 0.15 * Double(best.1))
        return SectionDecision(kind: best.0, suggestedTitle: "", confidence: confidence, source: .keywords)
    }
}
