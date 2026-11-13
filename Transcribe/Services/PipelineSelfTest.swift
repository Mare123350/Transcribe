#if DEBUG
import AppKit
import Exporter
import Foundation
import SwiftData
import Transcriber

/// Debug-only: launch with `-PipelineSelfTest` to push a scripted service through the real
/// detection pipeline (songs, scripture, headers) in an in-memory store, write the Markdown export
/// to the app's temporary folder, and quit. Lets the pipeline be checked without a microphone.
@MainActor
enum PipelineSelfTest {
    static var isRequested: Bool { CommandLine.arguments.contains("-PipelineSelfTest") }

    static let script: [String] = [
        "Good morning everyone, and welcome to Grace Church.",
        "If this is your first time with us, we're so glad you're here. Please fill in a welcome card and we'd love to meet you after the service.",
        "Let's stand and sing together.",
        "Amazing grace, how sweet the sound, that saved a wretch like me.",
        "I once was lost, but now am found, was blind, but now I see.",
        "'Twas grace that taught my heart to fear, and grace my fears relieved.",
        "How precious did that grace appear the hour I first believed.",
        "Amen. You may be seated.",
        "A few announcements this week. The youth group meets on Wednesday at seven in the fellowship hall.",
        "Sign up for the church picnic on Saturday is in the foyer, and we need volunteers for the kitchen team. Small groups start again next Sunday, so check the bulletin for times and places.",
        "Please turn with me to John chapter 3, verse 16.",
        "For God so loved the world, that he gave his only begotten Son, that whosoever believeth in him should not perish, but have everlasting life.",
        "So what does it mean to wait on the Lord? Abraham waited twenty-five years for the promise of a son. Faith is not passive, church.",
        "Faith is trusting God in the waiting room, when nothing seems to be happening and the promise feels far away. God was working in Abraham's waiting, and he is working in yours.",
        "And Solomon tells us, trust in the Lord with all your heart, and do not lean on your own understanding.",
        "When we wait, we are tempted to take control, to make it happen ourselves, like Abraham did with Hagar. But waiting on God means letting him be God, and trusting his timing more than our own.",
        "As the ushers come forward for the offering, remember God loves a cheerful giver. You can give online or use the envelopes in front of you.",
        "Now may the Lord bless you and keep you. Go in peace, have a great week, and we'll see you next Sunday.",
    ]

    static func run(_ model: AppModel) async {
        // Wait for the translations and verse index.
        while !model.scripture.isQuoteIndexReady { try? await Task.sleep(for: .milliseconds(200)) }
        let session = model.newSession()
        session.title = "Pipeline Self-Test"
        var time: TimeInterval = 0
        // -PipelineSelfTestRepeat N: a long service, with simulated partial results, for profiling.
        let repeats = max(1, UserDefaults.standard.integer(forKey: "PipelineSelfTestRepeat"))
        let clock = ContinuousClock()
        let started = clock.now
        for line in (0..<repeats).flatMap({ _ in script }) {
            if repeats > 1 {
                let words = line.split(separator: " ")
                for count in stride(from: 1, through: words.count, by: 2) {
                    model.recorder.debugSetVolatile(words.prefix(count).joined(separator: " "))
                    await Task.yield()
                }
            }
            let item = TranscriptItem(kind: .segment, sortIndex: session.nextSortIndex, timestamp: time)
            item.text = line
            time += Double(line.split(separator: " ").count) * 0.4
            item.endTimestamp = time
            model.context.insert(item)
            item.session = session
            await model.analyseForSelfTest(item, in: session)
        }
        if repeats > 1 { print("SELFTEST_TIME \(clock.now - started) for \(repeats * script.count) segments") }
        await model.sections.flush(in: session)
        try? model.context.save()

        let document = ExportService.document(for: session, includeTimestamps: true, summary: nil)
        let url = URL.temporaryDirectory.appending(path: "pipeline-self-test.md")
        try? Data(Exporter.markdown(document).utf8).write(to: url)
        print("SELFTEST_OUTPUT \(url.path)")
        NSApp.terminate(nil)
    }
}
#endif
