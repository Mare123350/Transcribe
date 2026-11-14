#if DEBUG
import AppKit
import Foundation
import ScriptureDetector
import SwiftUI

/// Debug-only: `-OutputSelfTest` runs the scripted service through the pipeline under each
/// auto-detect mode, checks what reaches Preview and Live, renders slides to PNG, and quits.
@MainActor
enum OutputSelfTest {
    static var isRequested: Bool { CommandLine.arguments.contains("-OutputSelfTest") }

    static func run(_ model: AppModel) async {
        while !model.scripture.isQuoteIndexReady { try? await Task.sleep(for: .milliseconds(200)) }
        let output = model.output
        var lines: [String] = []
        let folder = URL.temporaryDirectory.appending(path: "output-self-test", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        func describe(_ cue: OutputCue?) -> String {
            guard let cue, let slide = cue.slide else { return "nothing" }
            return "\(slide.heading) [\(slide.label)] page \(cue.page + 1)/\(cue.slides.count): \(slide.text.prefix(60))…"
        }
        func settle() async { try? await Task.sleep(for: .milliseconds(400)) }
        func render(_ name: String, _ slide: OutputSlide?) {
            let renderer = ImageRenderer(content: OutputSlideView(slide: slide, theme: output.theme).frame(width: 960, height: 540))
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: folder.appending(path: "\(name).png"))
            }
        }
        func feed(_ script: [String], clear: Bool = true) async -> Session {
            if clear {
                model.output.clearScreen()
                while model.output.preview != nil { model.output.skipPreview() }
            }
            let session = model.newSession()
            model.scripture.reset()
            var time: TimeInterval = 0
            for line in script {
                let item = TranscriptItem(kind: .segment, sortIndex: session.nextSortIndex, timestamp: time)
                item.text = line
                time += Double(line.split(separator: " ").count) * 0.4
                item.endTimestamp = time
                model.context.insert(item)
                item.session = session
                await model.analyseForSelfTest(item, in: session)
            }
            await settle()
            return session
        }

        // 1. Detect to Preview: verses queue for the operator; nothing goes live by itself.
        output.mode = .preview
        _ = await feed(PipelineSelfTest.script)
        lines.append("PREVIEW MODE")
        lines.append("  live: \(describe(output.live))")
        lines.append("  preview: \(describe(output.preview))")
        lines.append("  waiting: \(output.queue.compactMap { $0.slide?.heading })")
        output.take()
        lines.append("  after Send: live = \(describe(output.live)); preview = \(describe(output.preview))")
        render("1-live-after-send", output.live?.slide)
        await output.step(verse: 1, onLive: true)
        lines.append("  next verse on live: \(describe(output.live))")
        await output.step(verse: -1, onLive: true)
        lines.append("  previous verse: \(describe(output.live))")

        // 2. Auto-send: the confident reference goes live without the operator.
        output.mode = .autoSend
        _ = await feed(["Please turn with me to Romans chapter eight, verses twenty eight through thirty nine."])
        lines.append("AUTO-SEND MODE")
        lines.append("  live: \(describe(output.live))")
        render("2-auto-sent-page1", output.live?.slide)
        await output.step(slide: 1, onLive: true)
        lines.append("  next slide: \(describe(output.live))")
        render("3-auto-sent-page2", output.live?.slide)

        // A low-confidence detection never goes live by itself.
        let before = describe(output.live)
        _ = await feed(["And Corinthians thirteen verse four says love is patient."], clear: false)
        lines.append("  low-confidence 'Corinthians 13:4' (number not heard): live unchanged = \(describe(output.live) == before); preview = \(describe(output.preview))")

        // 3. Dismissing a card that's live takes it off the screen at once.
        if case .callout(let id)? = output.live?.source, let item = model.selectedSession?.items.first(where: { $0.id == id }) {
            model.scripture.remove(item)
        } else if let session = model.selectedSession, let verse = session.layout.verses.first {
            await output.send(.callout(verse.id))
            model.scripture.remove(verse)
        }
        lines.append("  after dismissing the live card: live = \(describe(output.live))")

        // 4. Fixing a card's version updates the screen.
        let fixSession = await feed(["Please turn with me to John 3:16."])
        if let verse = fixSession.layout.verses.first {
            await output.send(.callout(verse.id))
            await model.scripture.changeVersion(of: verse, to: "WEB")
            await settle()
            lines.append("OPERATOR FIX: version changed to WEB -> live = \(describe(output.live))")
            render("4-after-fix", output.live?.slide)
        }

        // 5. Off: nothing is queued.
        output.mode = .off
        _ = await feed(["Turn to Psalm 23."])
        lines.append("OFF MODE: preview = \(describe(output.preview)), live = \(describe(output.live))")

        // 6. A song in Preview mode, then followed along once sent.
        output.mode = .preview
        _ = await feed(Array(PipelineSelfTest.script[3...6]))
        lines.append("SONG: preview = \(describe(output.preview))")
        if case .song? = output.preview?.source { output.take() }
        render("5-song", output.live?.slide)
        lines.append("  live = \(describe(output.live))")

        // 7. Typed by hand: only that verse shows, even with detections waiting.
        output.clearScreen()
        output.mode = .preview
        _ = await feed(["Turn to Romans 8:28.", "And Isaiah 40:31."], clear: false)
        lines.append("BEFORE TYPING: preview = \(describe(output.preview)), waiting \(output.queue.count)")
        let chapterOnly = ReferenceParser.parseEntry("gen 1", versions: ["KJV"])?.reference.reference
        lines.append("TYPED 'gen 1': has a verse = \(chapterOnly?.verseStart != nil) (the field asks for one)")
        let versions = model.scripture.allVersionNames.map(\.abbreviation)
        if let typed = ReferenceParser.parseEntry("phil 4 13 web", versions: versions) {
            let version = typed.version ?? model.scripture.defaultAbbreviation
            model.scripture.remember(typed.reference.reference, version: version)
            await output.previewOnly(.passage(typed.reference.reference, version: version))
            lines.append("TYPED 'phil 4 13 web': preview = \(describe(output.preview)), waiting \(output.queue.count)")
            output.take()
            lines.append("  sent: live = \(describe(output.live)); preview afterwards = \(describe(output.preview))")
            render("6-typed", output.live?.slide)
        }
        if let typed = ReferenceParser.parseEntry("ps 23", versions: versions), let session = model.selectedSession {
            await model.scripture.insertManual(typed.reference.reference, abbreviation: model.scripture.defaultAbbreviation, in: session, at: 0)
            let card = session.layout.verses.last
            lines.append("TYPED 'ps 23' into the transcript: card = \(card?.reference ?? "none") \(card?.versionAbbreviation ?? ""), \(card?.verseText.split(separator: " ").count ?? 0) words")
        }
        lines.append("recent: \(model.scripture.recentVerses.prefix(3).map { "\($0.reference) \($0.version)" })")

        output.mode = .preview
        try? lines.joined(separator: "\n").write(to: folder.appending(path: "report.txt"), atomically: true, encoding: .utf8)
        print("OUTPUTTEST_OUTPUT \(folder.path)")
        exit(0)
    }
}
#endif
