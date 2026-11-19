import AppKit
import Foundation
import Observation
import ScriptureDetector
import SwiftData
import SwiftUI
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
    /// The main window's width, so the toolbar can switch to icons when it's narrow.
    var windowWidth: CGFloat = 1440
    /// The transcript column's width: what the toolbar actually has to fit into.
    var detailWidth: CGFloat = 900
    var isChoosingInput = false
    #if DEBUG
    /// Screenshot tour: text to put in the Screen search field, and a request to open the library.
    var debugSearchText = ""
    var debugOpenLibrary = 0
    #endif
    /// The main window, so screen keys only act there.
    weak var mainWindow: NSWindow?
    private var keyMonitor: Any?
    private var displayObserver: NSObjectProtocol?

    /// Presentation-style keys in the main window when nothing is being typed: Return or Space
    /// sends the preview to the screen, Escape clears the screen, Delete clears the preview.
    func installScreenKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = event.window, window === self.mainWindow, window.attachedSheet == nil,
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return event }
            // Typing in a field or editor: the keys are text.
            if let text = window.firstResponder as? NSText, text.isEditable { return event }
            switch event.keyCode {
            case 36, 76, 49: // Return, Enter, Space
                guard self.output.preview != nil else { return event }
                withAnimation(Design.slideAnimation) { self.output.take() }
                return nil
            case 53: // Escape
                guard self.output.live != nil else { return event }
                withAnimation(Design.slideAnimation) { self.output.clearScreen() }
                return nil
            case 51: // Delete
                guard self.output.preview != nil else { return event }
                self.output.clearPreview()
                return nil
            default:
                return event
            }
        }
        displayObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.output.displaysChanged() }
        }
    }

    /// Bumped by ⌘K to put the cursor in the verse entry field.
    var verseEntryFocusRequest = 0

    let scripture: ScriptureService
    let songs: SongService
    let sections: SectionService
    let output: OutputController
    /// Makes full transcripts from saved audio.
    let transcriptGenerator = TranscriptGenerator()

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
        self.output = OutputController(context: container.mainContext, scripture: scripture)
        let (stream, continuation) = AsyncStream.makeStream(of: SegmentRef.self)
        self.segments = continuation
        let (sectionStream, sectionContinuation) = AsyncStream.makeStream(of: SegmentRef.self)
        self.sectionSegments = sectionContinuation
        recoverInterruptedSessions()

        recorder.onSegment = { [continuation] item, session in
            continuation.yield(SegmentRef(item: item, session: session, isSaved: item.modelContext != nil))
        }
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
        scripture.onDetected = { [weak self] item, confidence in self?.output.detected(item, confidence: confidence) }
        scripture.onCalloutChanged = { [weak self] item in self?.output.calloutChanged(item) }
        scripture.onCalloutRemoved = { [weak self] id in self?.output.calloutRemoved(id) }
        songs.onSectionSung = { [weak self] item, section, confidence in self?.output.sectionSung(item, section: section, confidence: confidence) }
        songs.load()
        Task { await scripture.load() }
        Task.detached(priority: .utility) {
            let locale = UserDefaults.standard.string(forKey: SettingsKey.locale) ?? Locale.current.identifier
            await TranscriberFactory.prewarm(locale: Locale(identifier: locale))
        }
        #if DEBUG
        if PipelineSelfTest.isRequested { Task { await PipelineSelfTest.run(self) } }
        if LiveSelfTest.isRequested { Task { await LiveSelfTest.run(self) } }
        if SoakSelfTest.isRequested { Task { await SoakSelfTest.run(self) } }
        if PerformanceSelfTest.isRequested { Task { await PerformanceSelfTest.run(self) } }
        if OutputSelfTest.isRequested { Task { await OutputSelfTest.run(self) } }
        if ScreenshotTour.label != nil { Task { await ScreenshotTour.run(self) } }
        #endif
    }

    #if DEBUG
    func analyseForSelfTest(_ segment: TranscriptItem, in session: Session) async {
        await analyse(segment, in: session)
    }
    #endif

    private func analyse(_ segment: TranscriptItem, in session: Session) async {
        let sung = await songs.process(segment, in: session)
        if !sung {
            await scripture.process(segment, in: session)
            #if DEBUG
            // The self-test checks the finished structure, so it classifies in step.
            if PipelineSelfTest.isRequested || OutputSelfTest.isRequested { await sections.process(segment, in: session); return }
            #endif
            pendingSectionSegments += 1
            sectionSegments.yield(SegmentRef(item: segment, session: session, isSaved: segment.modelContext != nil))
        }
    }

    var context: ModelContext { container.mainContext }

    // MARK: - Partial text

    private var latestPartial: (text: String, session: Session)?
    private var partialTask: Task<Void, Never>?
    private var latestPartialTime: TimeInterval = 0

    /// In-progress text is checked for songs and scripture at most every 250 ms, newest text first.
    private func partialTextChanged(_ text: String, in session: Session) {
        latestPartial = (text, session)
        latestPartialTime = recorder.currentTime
        guard partialTask == nil else { return }
        partialTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self else { return }
            self.partialTask = nil
            guard let (text, session) = self.latestPartial, !text.isEmpty else { return }
            let time = self.latestPartialTime
            // Songs first: a line being sung shouldn't also be read as a quoted verse.
            await self.songs.processPartial(text, in: session, at: time)
            guard !self.songs.isSinging else { return }
            await self.scripture.processPartial(text, in: session, at: time)
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
        transcriptGenerator.cancel(session)
        ServiceAudio.delete(for: session.id)
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

    // MARK: - Set list and hand-picked items

    /// Adds a verse card to the selected service at the current point.
    func insertVerse(_ reference: BibleReference, version: String) {
        guard let session = selectedSession else { return }
        let time = recorder.session === session ? recorder.currentTime : session.duration
        Task { await scripture.insertManual(reference, abbreviation: version, in: session, at: time) }
    }

    /// Adds a song or verse to the selected service's set list (making a service if there's none).
    func addToSetList(_ kind: SetListItem.Kind, title: String) {
        let session = selectedSession ?? newSession()
        session.setList.append(SetListItem(kind: kind, title: title))
        try? context.save()
    }

    func removeFromSetList(_ item: SetListItem) {
        guard let session = selectedSession else { return }
        session.setList.removeAll { $0.id == item.id }
    }

    func moveSetList(from offsets: IndexSet, to destination: Int) {
        guard let session = selectedSession else { return }
        var list = session.setList
        list.move(fromOffsets: offsets, toOffset: destination)
        session.setList = list
    }

    func source(for item: SetListItem) -> OutputSource {
        switch item.kind {
        case .song(let id): .librarySong(id, section: 0)
        case .verse(let reference, let version): .passage(reference, version: version)
        }
    }

    /// The set list item now on screen (or in Preview), if any.
    var currentSetListIndex: Int? {
        guard let list = selectedSession?.setList else { return nil }
        for cue in [output.live, output.preview].compactMap({ $0 }) {
            if let index = list.firstIndex(where: { source(for: $0) .matches(cue.source) }) { return index }
        }
        return nil
    }

    /// ⌥⌘↓ / ⌥⌘↑: puts the next (or previous) set list item in Preview.
    func stepSetList(by delta: Int) {
        guard let list = selectedSession?.setList, !list.isEmpty else { return }
        let target = currentSetListIndex.map { $0 + delta } ?? (delta > 0 ? 0 : list.count - 1)
        guard list.indices.contains(target) else { return }
        Task { await output.previewOnly(source(for: list[target])) }
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
    /// False for phrases heard in "Scripture and songs only": detached items that are never saved.
    let isSaved: Bool

    /// Nil if either was deleted while waiting.
    @MainActor var live: (TranscriptItem, Session)? {
        guard !item.isDeleted, !isSaved || item.modelContext != nil, !session.isDeleted, session.modelContext != nil else { return nil }
        return (item, session)
    }
}
