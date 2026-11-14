import Foundation
import Observation
import SwiftData
import Transcriber

/// App-wide state shared by the main window, menus, presentation window, and settings.
@MainActor
@Observable
final class AppModel {
    let container: ModelContainer
    let recorder: RecordingController

    var selectedSession: Session?
    var showInspector = true
    /// The transcript item the transcript view should scroll to (set from the inspector).
    var scrollTarget: UUID?

    // Sheets triggered from menus and shortcuts.
    var isInsertingHeader = false
    var isInsertingVerse = false
    var isExporting = false

    let scripture: ScriptureService
    let songs: SongService
    let sections: SectionService

    /// Finalized segments are analysed one at a time, in order. Songs and scripture are quick;
    /// section headers wait for the on-device language model (seconds), so they run in their own
    /// queue and never hold up a verse card.
    private let segments: AsyncStream<SegmentRef>.Continuation
    private let sectionSegments: AsyncStream<SegmentRef>.Continuation
    private var pipelineTask: Task<Void, Never>?
    private var sectionTask: Task<Void, Never>?
    private var pendingSectionSegments = 0

    init(container: ModelContainer) {
        self.container = container
        self.recorder = RecordingController(context: container.mainContext)
        self.scripture = ScriptureService(context: container.mainContext)
        self.songs = SongService(context: container.mainContext)
        self.sections = SectionService(context: container.mainContext)
        let (stream, continuation) = AsyncStream.makeStream(of: SegmentRef.self)
        self.segments = continuation
        let (sectionStream, sectionContinuation) = AsyncStream.makeStream(of: SegmentRef.self)
        self.sectionSegments = sectionContinuation
        recoverInterruptedSessions()

        recorder.onSegment = { [continuation] item, session in continuation.yield(SegmentRef(item: item, session: session)) }
        pipelineTask = Task { [weak self] in
            for await ref in stream {
                guard let self, let (item, session) = ref.live else { continue }
                await self.analyse(item, in: session)
            }
        }
        sectionTask = Task { [weak self] in
            for await ref in sectionStream {
                guard let self else { continue }
                if let (item, session) = ref.live { await self.sections.process(item, in: session) }
                self.pendingSectionSegments -= 1
            }
        }
        recorder.onTick = { [weak self] _, _ in self?.songs.tick() }
        recorder.onVolatile = { [weak self] text, session in self?.partialTextChanged(text, in: session) }
        songs.onSongStarted = { [weak self] song, session in self?.sections.songStarted(song, in: session) }
        scripture.onPassageRead = { [weak self] callout, session in self?.sections.passageRead(callout, in: session) }
        songs.load()
        Task { await scripture.load() }
        Task.detached(priority: .utility) {
            let locale = UserDefaults.standard.string(forKey: SettingsKey.locale) ?? Locale.current.identifier
            await TranscriberFactory.prewarm(locale: Locale(identifier: locale))
        }
        #if DEBUG
        if PipelineSelfTest.isRequested { Task { await PipelineSelfTest.run(self) } }
        if LiveSelfTest.isRequested { Task { await LiveSelfTest.run(self) } }
        if PerformanceSelfTest.isRequested { Task { await PerformanceSelfTest.run(self) } }
        #endif
    }

    #if DEBUG
    func analyseForSelfTest(_ segment: TranscriptItem, in session: Session) async {
        await analyse(segment, in: session)
    }
    #endif

    private func analyse(_ segment: TranscriptItem, in session: Session) async {
        let sung = songs.process(segment, in: session)
        if !sung {
            await scripture.process(segment, in: session)
            #if DEBUG
            // The self-test checks the finished structure, so it classifies in step.
            if PipelineSelfTest.isRequested { await sections.process(segment, in: session); return }
            #endif
            pendingSectionSegments += 1
            sectionSegments.yield(SegmentRef(item: segment, session: session))
        }
    }

    var context: ModelContext { container.mainContext }

    // MARK: Partial text

    private var latestPartial: (text: String, session: Session)?
    private var partialTask: Task<Void, Never>?

    /// In-progress text is checked for scripture at most every 250 ms, newest text first.
    private func partialTextChanged(_ text: String, in session: Session) {
        latestPartial = (text, session)
        guard partialTask == nil else { return }
        partialTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self else { return }
            self.partialTask = nil
            guard let (text, session) = self.latestPartial, !text.isEmpty, !self.songs.isSinging else { return }
            await self.scripture.processPartial(text, in: session)
        }
    }

    // MARK: - Sessions

    @discardableResult
    func newSession() -> Session {
        let session = Session(title: Session.defaultTitle(), localeIdentifier: UserDefaults.standard.string(forKey: SettingsKey.locale) ?? Locale.current.identifier)
        context.insert(session)
        try? context.save()
        selectedSession = session
        return session
    }

    func delete(_ session: Session) {
        guard recorder.session !== session || !recorder.isActive else { return }
        if selectedSession === session { selectedSession = nil }
        context.delete(session)
        try? context.save()
    }

    /// ⌘R: records into the selected session if it's empty, otherwise into a new one; pauses or
    /// resumes if a recording is already running.
    func toggleRecording() async {
        if recorder.isActive, let active = recorder.session {
            selectedSession = active
            await recorder.toggleRecordPause(into: active)
            return
        }
        let target: Session
        if let selected = selectedSession, selected.items.isEmpty {
            target = selected
        } else {
            target = newSession()
        }
        selectedSession = target
        resetDetectors()
        await recorder.start(into: target)
    }

    /// Continues recording into the selected session, keeping its timeline.
    func continueRecording() async {
        guard !recorder.isActive, let selected = selectedSession else { return }
        resetDetectors()
        await recorder.start(into: selected)
    }

    func stopRecording() async {
        let session = recorder.session
        await recorder.stop()
        // Let queued lines reach the classifier before the last section is flushed.
        let deadline = ContinuousClock.now + .seconds(20)
        while pendingSectionSegments > 0 && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        if let session { await sections.flush(in: session) }
    }

    private func resetDetectors() {
        songs.reset()
        scripture.reset()
        sections.reset()
    }

    // MARK: - Headers

    /// The header whose title should take keyboard focus when it appears.
    var focusHeaderID: UUID?

    @discardableResult
    func insertHeader(_ section: ServiceSection = .other, title: String? = nil, before item: TranscriptItem, in session: Session) -> TranscriptItem {
        makeHeader(section, title: title, sortIndex: session.sortIndex(before: item), timestamp: item.timestamp, in: session)
    }

    /// ⌘H: adds a header at the current end of the transcript and focuses its title.
    func insertHeaderAtEnd() {
        guard let session = selectedSession else { return }
        let time = recorder.session === session ? recorder.currentTime : session.duration
        let header = makeHeader(.other, title: "", sortIndex: session.nextSortIndex, timestamp: time, in: session)
        header.isUserEdited = true
        focusHeaderID = header.id
        scrollTarget = header.id
    }

    private func makeHeader(_ section: ServiceSection, title: String?, sortIndex: Double, timestamp: TimeInterval, in session: Session) -> TranscriptItem {
        let header = TranscriptItem(kind: .header, sortIndex: sortIndex, timestamp: timestamp)
        header.sectionType = section
        header.title = title ?? section.title
        context.insert(header)
        header.session = session
        return header
    }

    /// A session still marked as recording at launch was interrupted (e.g. a crash). Everything up
    /// to the last autosave is already on disk; just clear the flag.
    private func recoverInterruptedSessions() {
        let descriptor = FetchDescriptor<Session>(predicate: #Predicate { $0.isRecording })
        guard let interrupted = try? context.fetch(descriptor), !interrupted.isEmpty else { return }
        for session in interrupted {
            session.isRecording = false
            if !session.title.hasSuffix("(recovered)") { session.title += " (recovered)" }
        }
        try? context.save()
    }
}

/// A segment waiting to be analysed. Passes the objects themselves: a persistent identifier taken
/// before the first save is temporary, and looking it up after an autosave crashes. Both ends of
/// the queues run on the main actor.
struct SegmentRef: @unchecked Sendable {
    let item: TranscriptItem
    let session: Session

    /// Nil if either was deleted while waiting.
    @MainActor var live: (TranscriptItem, Session)? {
        guard !item.isDeleted, item.modelContext != nil, !session.isDeleted, session.modelContext != nil else { return nil }
        return (item, session)
    }
}
