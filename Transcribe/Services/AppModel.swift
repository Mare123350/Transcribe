import Foundation
import Observation
import SwiftData

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

    /// Finalized segments are analysed one at a time, in order, by each detector.
    private let segments: AsyncStream<(PersistentIdentifier, PersistentIdentifier)>.Continuation
    private var pipelineTask: Task<Void, Never>?

    init(container: ModelContainer) {
        self.container = container
        self.recorder = RecordingController(context: container.mainContext)
        self.scripture = ScriptureService(context: container.mainContext)
        self.songs = SongService(context: container.mainContext)
        self.sections = SectionService(context: container.mainContext)
        let (stream, continuation) = AsyncStream.makeStream(of: (PersistentIdentifier, PersistentIdentifier).self)
        self.segments = continuation
        recoverInterruptedSessions()

        recorder.onSegment = { [continuation] item, session in continuation.yield((item.persistentModelID, session.persistentModelID)) }
        pipelineTask = Task { [weak self] in
            for await (itemID, sessionID) in stream {
                guard let self,
                      let item = self.context.model(for: itemID) as? TranscriptItem,
                      let session = self.context.model(for: sessionID) as? Session else { continue }
                await self.analyse(item, in: session)
            }
        }
        recorder.onTick = { [weak self] _, _ in self?.songs.tick() }
        songs.onSongStarted = { [weak self] song, session in self?.sections.songStarted(song, in: session) }
        scripture.onPassageRead = { [weak self] callout, session in self?.sections.passageRead(callout, in: session) }
        songs.load()
        Task { await scripture.load() }
        #if DEBUG
        if PipelineSelfTest.isRequested { Task { await PipelineSelfTest.run(self) } }
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
            await sections.process(segment, in: session)
        }
    }

    var context: ModelContext { container.mainContext }

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
