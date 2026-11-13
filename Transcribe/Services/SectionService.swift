import Foundation
import Observation
import SectionClassifier
import SwiftData
import TranscribeCore

/// Inserts section headers (Welcome, Worship, Sermon…) as the service moves on.
///
/// Finalized speech is classified in chunks of about 60 words. A new header goes in when the
/// section changes and the classifier is confident (≥ 0.8), or when two chunks in a row agree.
/// A song from the library starting means worship. Sermons get a descriptive subheader.
@MainActor
@Observable
final class SectionService {
    private(set) var status: IntelligenceStatus = .current

    private let context: ModelContext
    private let classifier = SectionClassifier()

    private var buffer = ""
    private var bufferWords = 0
    private var bufferSegmentIDs: [UUID] = []
    /// A change seen once, waiting for a second chunk to agree.
    private var pending: (kind: ServiceSectionKind, segmentIDs: [UUID], title: String)?
    private var sermonHeaderID: UUID?
    private var sermonText = ""
    private var sermonTitleRequested = false

    static let chunkWords = 35
    static let sermonTitleWords = 250

    init(context: ModelContext) {
        self.context = context
    }

    var isEnabled: Bool { UserDefaults.standard.object(forKey: SettingsKey.autoHeaders) as? Bool ?? true }

    func refreshStatus() { status = .current }

    func reset() {
        buffer = ""
        bufferWords = 0
        bufferSegmentIDs = []
        pending = nil
        sermonHeaderID = nil
        sermonText = ""
        sermonTitleRequested = false
        status = .current
    }

    // MARK: Live

    func process(_ segment: TranscriptItem, in session: Session) async {
        guard isEnabled else { return }
        bufferSegmentIDs.append(segment.id)
        buffer += (buffer.isEmpty ? "" : " ") + segment.text
        bufferWords += segment.text.split(separator: " ").count

        if currentSection(in: session) == .sermon {
            sermonText += " " + segment.text
            await maybeTitleSermon(in: session)
        }

        guard bufferWords >= Self.chunkWords else { return }
        let text = buffer
        let chunk = bufferSegmentIDs
        buffer = ""
        bufferWords = 0
        bufferSegmentIDs = []

        await classify(text, chunk: chunk, in: session)
    }

    /// Classifies whatever is left when recording stops, so the last section gets its header.
    func flush(in session: Session) async {
        guard isEnabled, bufferWords >= 8 else { return }
        let text = buffer
        let chunk = bufferSegmentIDs
        buffer = ""
        bufferWords = 0
        bufferSegmentIDs = []
        await classify(text, chunk: chunk, in: session)
    }

    private func classify(_ text: String, chunk: [UUID], in session: Session) async {
        let current = currentSection(in: session)
        let decision = await classifier.classify(text, previous: current)
        await apply(decision, chunk: chunk, current: current, in: session)

        // The chunk's last line may already start the next section ("…envelopes. Go in peace.").
        if chunk.count >= 2, let last = chunk.last.flatMap(item) {
            let cue = KeywordSectionClassifier.classify(last.text)
            if cue.confidence >= 0.75, cue.kind != currentSection(in: session) {
                insertHeader(cue.kind, title: "", before: last, in: session, confidence: cue.confidence)
                pending = nil
            }
        }
    }

    /// A library song started: that's worship, unless we're already in it.
    func songStarted(_ song: TranscriptItem, in session: Session) {
        guard isEnabled, currentSection(in: session, before: song) != .worship else { return }
        insertHeader(.worship, title: "", before: song, in: session, confidence: song.confidence)
        pending = nil
    }

    /// A referenced passage is being read aloud. Outside the sermon, that's a scripture reading:
    /// the header goes before the line that announced it ("Please turn with me to John 3:16").
    func passageRead(_ callout: TranscriptItem, in session: Session) {
        guard isEnabled else { return }
        let current = currentSection(in: session, before: callout)
        guard current != .scriptureReading && current != .sermon else { return }
        let announcement = session.items
            .filter { $0.kind == .segment && $0.parentItemID == nil && $0.sortIndex < callout.sortIndex }
            .max { $0.sortIndex < $1.sortIndex }
        insertHeader(.scriptureReading, title: "", before: announcement ?? callout, in: session, confidence: 0.9)
        pending = nil
    }

    private func apply(_ decision: SectionDecision, chunk: [UUID], current: ServiceSectionKind?, in session: Session) async {
        guard decision.kind != current else {
            pending = nil
            return
        }
        let confident = decision.confidence >= 0.8 && decision.source == .model
        let confirmed = pending?.kind == decision.kind && decision.confidence >= 0.5
        // With keyword matching only, a single clear cue is enough at the very start.
        let firstHeader = current == nil && decision.confidence >= 0.6

        guard confident || confirmed || firstHeader else {
            pending = (decision.kind, chunk, decision.suggestedTitle)
            return
        }
        // When two chunks agreed, the section started somewhere in the first of them.
        let candidates = confirmed ? (pending?.segmentIDs ?? []) + chunk : chunk
        let title = decision.suggestedTitle.isEmpty ? (pending?.title ?? "") : decision.suggestedTitle
        pending = nil
        guard let start = await firstSegment(of: decision.kind, among: candidates) else { return }
        insertHeader(decision.kind, title: title, before: start, in: session, confidence: decision.confidence)
    }

    /// A chunk can straddle two sections ("…see you at the picnic. Let's pray."). Find the segment
    /// where `kind` begins: by its telltale phrases if it has any, otherwise by asking the classifier
    /// about each line. Falls back to the start of the chunk.
    private func firstSegment(of kind: ServiceSectionKind, among ids: [UUID]) async -> TranscriptItem? {
        let segments = ids.compactMap(item).filter { $0.parentItemID == nil || $0.kind == .segment }
        guard segments.count > 1 else { return segments.first }
        for segment in segments {
            let cue = KeywordSectionClassifier.classify(segment.text)
            if cue.kind == kind && cue.confidence >= 0.6 { return segment }
        }
        for segment in segments where segment.text.split(separator: " ").count >= 4 {
            if await classifier.classify(segment.text, previous: nil).kind == kind { return segment }
        }
        return segments.first
    }

    private func insertHeader(_ kind: ServiceSectionKind, title: String, before item: TranscriptItem, in session: Session, confidence: Double) {
        let section = ServiceSection(rawValue: kind.rawValue) ?? .other
        let header = TranscriptItem(kind: .header, sortIndex: session.sortIndex(before: item), timestamp: item.timestamp)
        header.sectionType = section
        header.title = section.title
        header.isAutomatic = true
        header.confidence = confidence
        context.insert(header)
        header.session = session

        if kind == .sermon {
            sermonHeaderID = header.id
            sermonText = ""
            sermonTitleRequested = false
            // The classifier's suggestion is a reasonable subheader until a proper title is ready.
            if !title.isEmpty && title.lowercased() != "sermon" { header.subtitle = title }
        }
    }

    private func maybeTitleSermon(in session: Session) async {
        guard !sermonTitleRequested, let id = sermonHeaderID,
              sermonText.split(separator: " ").count >= Self.sermonTitleWords else { return }
        sermonTitleRequested = true
        guard let title = await classifier.sermonTitle(for: sermonText),
              let header = item(id), !header.isUserEdited else { return }
        header.subtitle = title
    }

    // MARK: Helpers

    /// The section in effect at the end of the transcript (or just before `item`).
    func currentSection(in session: Session, before item: TranscriptItem? = nil) -> ServiceSectionKind? {
        let limit = item?.sortIndex ?? .infinity
        let header = session.layout.headers.last { $0.sortIndex < limit }
        return header?.sectionType.flatMap { ServiceSectionKind(rawValue: $0.rawValue) }
    }

    /// Items this service has looked up, so the main thread doesn't run a fetch per lookup.
    private var known: [UUID: TranscriptItem] = [:]

    private func item(_ id: UUID) -> TranscriptItem? {
        if let cached = known[id], !cached.isDeleted, cached.modelContext != nil { return cached }
        let found = try? context.fetch(FetchDescriptor<TranscriptItem>(predicate: #Predicate { $0.id == id })).first
        known[id] = found
        return found
    }
}
