#if DEBUG
import AppKit
import Foundation
import ScriptureDetector
import SwiftData

/// Debug-only: launch with `-PerformanceSelfTest` to build a 2-hour service in memory and time
/// what grows with transcript length: ordering, detection per new line, switching services and
/// scrolling. Writes the results to the app's temporary folder and quits.
@MainActor
enum PerformanceSelfTest {
    static var isRequested: Bool { CommandLine.arguments.contains("-PerformanceSelfTest") }

    static let filler = [
        "And so church, when we think about what it means to follow him, we have to remember that grace comes first.",
        "Some of you have been waiting a long time for an answer, and I want you to know that he has not forgotten you.",
        "Let me tell you a story about a man in our town who lost everything and found that God was still faithful.",
        "This is not about trying harder; it is about trusting more, and letting the Spirit do the work in us.",
    ]

    static func run(_ model: AppModel) async {
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Self-test")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        while !model.scripture.isQuoteIndexReady { try? await Task.sleep(for: .milliseconds(200)) }
        let clock = ContinuousClock()
        var lines: [String] = []
        func measure<T>(_ label: String, _ body: () -> T) -> T {
            let start = clock.now
            let result = body()
            lines.append("\(label): \(format(clock.now - start))")
            return result
        }

        // A 2-hour service: a line every 3 seconds, with headers, songs (with sung lines folded
        // under them) and verse callouts.
        let small = model.newSession()
        small.title = "Short service"
        let session = model.newSession()
        session.title = "Two-hour service"
        var sortIndex = 0.0
        var time = 0.0
        func add(_ kind: ItemKind, _ configure: (TranscriptItem) -> Void = { _ in }) -> TranscriptItem {
            sortIndex += 1
            let item = TranscriptItem(kind: kind, sortIndex: sortIndex, timestamp: time)
            configure(item)
            model.context.insert(item)
            item.session = session
            return item
        }
        for index in 0..<2400 {
            time = Double(index) * 3
            if index % 200 == 0 { _ = add(.header) { $0.title = "Section \(index / 200 + 1)" } }
            if index % 160 == 40 {
                let song = add(.song) { $0.title = "Song \(index)" }
                for line in 0..<8 { _ = add(.segment) { $0.text = "Sung line \(line)"; $0.parentItemID = song.id } }
            }
            _ = add(.segment) { $0.text = filler[index % filler.count] }
            if index % 60 == 30 {
                _ = add(.verse) { item in
                    item.reference = "John 3:16"; item.referenceKey = "JHN.3.16-16"; item.versionAbbreviation = "KJV"
                    item.verseText = "For God so loved the world, that he gave his only begotten Son."
                }
            }
        }
        session.duration = time
        try? model.context.save()
        lines.append("items: \(session.items.count)")

        _ = measure("layout, first build") { session.layout.topLevel.count }
        _ = measure("layout, cached read") { session.layout.topLevel.count }
        _ = measure("next sort index") { session.nextSortIndex }

        // Detection for new lines at the end of a long service (songs + scripture, on the main actor).
        var perLine: [Duration] = []
        for index in 0..<40 {
            time += 3
            let item = TranscriptItem(kind: .segment, sortIndex: session.nextSortIndex, timestamp: time)
            item.text = index == 20 ? "Please turn with me to Romans 8:28." : filler[index % filler.count]
            model.context.insert(item)
            item.session = session
            let start = clock.now
            await model.analyseForSelfTest(item, in: session)
            perLine.append(clock.now - start)
        }
        perLine.sort()
        lines.append("detection per new line: median \(format(perLine[perLine.count / 2])), max \(format(perLine.last!))")

        // Switching services, then scrolling top to bottom, watching for main-thread stalls.
        model.selectedSession = small
        try? await Task.sleep(for: .milliseconds(500))
        let switchStart = clock.now
        model.selectedSession = session
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(1))
        lines.append("switch to the 2-hour service (until the next main-thread turn): \(format(clock.now - switchStart))")
        try? await Task.sleep(for: .seconds(1))

        // Scroll the transcript like a user would: move its scroll view a little every frame.
        guard let scrollView = transcriptScrollView() else {
            lines.append("scrolling: transcript scroll view not found")
            return finish(lines)
        }
        var maxGap = Duration.zero
        var frames = 0
        var last = clock.now
        let scrollStart = clock.now
        var y: CGFloat = 0
        print("SCROLL_START \(Date().timeIntervalSince1970)")
        while true {
            let height = scrollView.documentView?.frame.height ?? 0
            let maxY = max(0, height - scrollView.contentView.bounds.height)
            guard y < maxY else { break }
            y = min(maxY, y + 60)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            frames += 1
            try? await Task.sleep(for: .milliseconds(16))
            let now = clock.now
            maxGap = max(maxGap, now - last)
            last = now
            if now - scrollStart > .seconds(90) { break }
        }
        _ = measure("for comparison, sorting all items as before") { session.items.sorted { $0.sortIndex < $1.sortIndex }.count }
        lines.append("scrolled to \(Int(y)) pt in \(frames) frames over \(format(clock.now - scrollStart)); longest frame: \(format(maxGap))")

        finish(lines)
    }

    /// The tallest scroll view in the main window: the transcript.
    static func transcriptScrollView() -> NSScrollView? {
        var found: [NSScrollView] = []
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView { found.append(scroll) }
            view.subviews.forEach(walk)
        }
        for window in NSApp.windows { if let content = window.contentView { walk(content) } }
        return found.max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
    }

    static func finish(_ lines: [String]) {
        let url = URL.temporaryDirectory.appending(path: "performance-self-test.txt")
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        print("PERFTEST_OUTPUT \(url.path)")
        exit(0)
    }

    static func format(_ duration: Duration) -> String {
        let ms = Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        return String(format: "%.1f ms", ms)
    }
}
#endif

#if DEBUG
import Darwin

/// Debug-only: `-LaunchTiming` prints how long after the process started the main window appeared
/// and the scripture index was ready, then quits.
@MainActor
enum LaunchTiming {
    static var isRequested: Bool { CommandLine.arguments.contains("-LaunchTiming") }

    static func sinceProcessStart() -> Double {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        sysctl(&mib, 4, &info, &size, nil, 0)
        let start = info.kp_proc.p_un.__p_starttime
        let started = Double(start.tv_sec) + Double(start.tv_usec) / 1e6
        return (Date().timeIntervalSince1970 - started) * 1000
    }

    static func windowAppeared(_ model: AppModel) {
        guard isRequested else { return }
        let window = sinceProcessStart()
        Task {
            while !model.scripture.isQuoteIndexReady { try? await Task.sleep(for: .milliseconds(10)) }
            let index = sinceProcessStart()
            let text = String(format: "window visible: %.0f ms after process start\nverse index ready: %.0f ms", window, index)
            try? text.write(to: URL.temporaryDirectory.appending(path: "launch-timing.txt"), atomically: true, encoding: .utf8)
            exit(0)
        }
    }
}
#endif
