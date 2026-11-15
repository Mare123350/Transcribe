#if DEBUG
import AppKit
import ScriptureDetector
import SwiftData
import SwiftUI

/// Debug-only: `-UIScreenshots <label>` fills an in-memory store with a demo service, then saves
/// window images (idle and recording, light and dark, three window sizes) to the app's temporary
/// folder under `screenshots/`, and quits. Used to review the UI without screen-recording access.
@MainActor
enum ScreenshotTour {
    static var label: String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "-UIScreenshots"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    static func run(_ model: AppModel) async {
        guard let label else { return }
        while !model.scripture.isQuoteIndexReady { try? await Task.sleep(for: .milliseconds(200)) }
        let folder = URL.temporaryDirectory.appending(path: "screenshots", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let session = await seed(model)
        // A couple of earlier services so the sidebar looks used.
        for (title, days) in [("Service — Sunday, Nov 8 at 10:00 AM", 6.0), ("Service — Sunday, Nov 1 at 10:00 AM", 13.0)] {
            let old = Session(title: title, localeIdentifier: "en_US")
            old.createdAt = .now.addingTimeInterval(-days * 86400)
            old.duration = 5400
            model.context.insert(old)
        }
        let empty = Session(title: "Service — Saturday, Nov 14 at 10:09 AM", localeIdentifier: "en_US")
        model.context.insert(empty)
        model.selectedSession = session
        model.showInspector = true
        try? await Task.sleep(for: .seconds(1))

        var found = mainWindow()
        for _ in 0..<50 where found == nil {
            try? await Task.sleep(for: .milliseconds(200))
            found = mainWindow()
        }
        guard let window = found else {
            print("no window: \(NSApp.windows.map { "\($0.title) visible=\($0.isVisible) mask=\($0.styleMask.rawValue)" })")
            exit(1)
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        let screen = window.screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1512, height: 945)
        let sizes: [(String, NSSize)] = [("min", NSSize(width: 1000, height: 560)), ("laptop", NSSize(width: 1440, height: 900)), ("full", screen.size)]

        // Songs: a planned set list, a song in Preview with its slide list, another live, and
        // search results for a misspelled title; then the song library window.
        if CommandLine.arguments.contains("-SongsStage") {
            for title in ["Amazing Grace", "Be Thou My Vision", "Doxology"] {
                if let song = model.songs.search(title, limit: 1).first?.song { model.addToSetList(.song(song.id), title: song.title) }
            }
            model.addToSetList(.verse(BibleReference(book: "JHN", chapter: 3, verseStart: 16), version: "KJV"), title: "John 3:16")
            if let live = model.songs.search("Amazing Grace", limit: 1).first?.song { await model.output.send(.librarySong(live.id, section: 1)) }
            if let next = model.songs.search("Be Thou My Vision", limit: 1).first?.song { await model.output.previewOnly(.librarySong(next.id, section: 0)) }
            model.debugSearchText = "amazng"
            for appearance in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                NSApp.appearance = NSAppearance(named: appearance.1)
                window.setFrame(NSRect(origin: screen.origin, size: NSSize(width: 1440, height: 900)), display: true)
                try? await Task.sleep(for: .milliseconds(900))
                await save(window, to: folder.appending(path: "\(label)-songs-\(appearance.0)-laptop.png"))
            }
            model.debugSearchText = ""
            model.debugOpenLibrary += 1
            try? await Task.sleep(for: .seconds(1.5))
            if let library = NSApp.windows.first(where: { $0.title == "Song Library" }) {
                library.setFrame(NSRect(origin: screen.origin, size: NSSize(width: 1100, height: 720)), display: true)
                library.makeKeyAndOrderFront(nil)
                for appearance in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                    NSApp.appearance = NSAppearance(named: appearance.1)
                    try? await Task.sleep(for: .milliseconds(900))
                    await save(library, to: folder.appending(path: "\(label)-library-\(appearance.0).png"))
                }
                library.close()
            }
            try? "done".write(to: folder.appending(path: "shot.txt"), atomically: true, encoding: .utf8)
            exit(0)
        }

        for state in ["idle", "recording"] {
            if state == "recording" { model.recorder.debugSimulateRecording(in: session) }
            for appearance in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                NSApp.appearance = NSAppearance(named: appearance.1)
                for (sizeName, size) in sizes {
                    if sizeName == "full" && appearance.0 == "dark" { continue }
                    window.setFrame(NSRect(origin: screen.origin, size: size), display: true)
                    try? await Task.sleep(for: .milliseconds(900))
                    await save(window, to: folder.appending(path: "\(label)-\(state)-\(appearance.0)-\(sizeName).png"))
                }
            }
        }
        try? "done".write(to: folder.appending(path: "shot.txt"), atomically: true, encoding: .utf8)
        print("SCREENSHOTS \(folder.path)")
        exit(0)
    }

    static func mainWindow() -> NSWindow? {
        NSApp.windows.filter { $0.styleMask.contains(.titled) && $0.title != "Output" && $0.contentView != nil }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    /// Asks the capture script (Tools/capture_screens.sh) to photograph this window, and waits
    /// for it. The app can't capture its own SwiftUI content; the script uses `screencapture -l`.
    static func save(_ window: NSWindow, to url: URL) async {
        let folder = url.deletingLastPathComponent()
        let name = url.deletingPathExtension().lastPathComponent
        let ack = folder.appending(path: "ack-\(name)")
        try? FileManager.default.removeItem(at: ack)
        try? "\(name) \(window.windowNumber)".write(to: folder.appending(path: "shot.txt"), atomically: true, encoding: .utf8)
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: ack.path) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? FileManager.default.removeItem(at: ack)
    }

    /// A believable service: headers, lines, a song, verse cards, and something in Preview and Live.
    static func seed(_ model: AppModel) async -> Session {
        let session = model.newSession()
        session.title = "Service — Saturday, Nov 14 at 10:41 AM"
        var time: TimeInterval = 0
        func line(_ text: String) {
            let item = TranscriptItem(kind: .segment, sortIndex: session.nextSortIndex, timestamp: time)
            item.text = text
            time += Double(text.split(separator: " ").count) * 0.45
            item.endTimestamp = time
            model.context.insert(item)
            item.session = session
        }
        func header(_ section: ServiceSection, _ title: String? = nil, subtitle: String = "") {
            let item = TranscriptItem(kind: .header, sortIndex: session.nextSortIndex, timestamp: time)
            item.sectionType = section
            item.title = title ?? section.title
            item.subtitle = subtitle
            item.isAutomatic = true
            model.context.insert(item)
            item.session = session
        }
        header(.welcome)
        line("Good morning everyone, and welcome to Grace Church. If this is your first time with us, we're so glad you're here.")
        line("Please fill in a welcome card and we'd love to meet you after the service.")
        header(.worship)
        if let song = try? model.context.fetch(FetchDescriptor<StoredSong>()).first(where: { $0.title.contains("Amazing") }) {
            model.songs.insert(song, in: session, at: time)
            if let item = session.layout.songs.last { item.lyricSections = Array(song.sections.prefix(2)) }
            time += 90
        }
        header(.scriptureReading)
        line("Please turn with me to John 3:16.")
        await model.scripture.insertManual(BibleReference(book: "JHN", chapter: 3, verseStart: 16), abbreviation: "KJV", in: session, at: time)
        line("For God so loved the world, that he gave his only begotten Son, that whosoever believeth in him should not perish, but have everlasting life.")
        header(.sermon, "Sermon", subtitle: "Faith in the Waiting Room")
        line("So what does it mean to wait on the Lord? Abraham waited twenty-five years for the promise of a son. Faith is not passive, church.")
        line("Faith is trusting God in the waiting room, when nothing seems to be happening and the promise feels far away.")
        line("And Solomon tells us, trust in the Lord with all your heart, and do not lean on your own understanding.")
        await model.scripture.insertManual(BibleReference(book: "PRO", chapter: 3, verseStart: 5), abbreviation: "BSB", in: session, at: time)
        session.duration = time
        if let verse = session.layout.verses.first { await model.output.previewOnly(.callout(verse.id)) }
        await model.output.send(.passage(BibleReference(book: "PSA", chapter: 23, verseStart: 1), version: "KJV"))
        model.scripture.remember(BibleReference(book: "PHP", chapter: 4, verseStart: 13), version: "KJV")
        model.scripture.remember(BibleReference(book: "ROM", chapter: 8, verseStart: 28), version: "KJV")
        return session
    }
}
#endif
