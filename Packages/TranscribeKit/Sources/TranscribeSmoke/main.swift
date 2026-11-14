// Developer tool: feeds an audio file through the live transcription pipeline, in real time-ish
// chunks, and prints the events. Usage: swift run TranscribeSmoke <audio-file> [locale]
@preconcurrency import AVFoundation
import AudioCapture
import Foundation
import ScriptureDetector
import SectionClassifier
import SongMatcher
import TranscribeCore
import Transcriber

let arguments = CommandLine.arguments
// SECTIONS=1: classify sample service excerpts and exit.
if ProcessInfo.processInfo.environment["SECTIONS"] != nil {
    print("Apple Intelligence: \(IntelligenceStatus.current)")
    let classifier = SectionClassifier()
    let samples = [
        "Good morning everyone and welcome to Grace Church. If this is your first time with us we're so glad you're here.",
        "Let's bow our heads. Heavenly Father, we thank you for this day and for bringing us together. In Jesus name, amen.",
        "A few things this week. The youth group meets Wednesday at seven, and sign up for the picnic is in the foyer.",
        "So what does it mean to wait on the Lord? Abraham waited twenty five years for the promise. Faith isn't passive, church. Faith is trusting God in the waiting room.",
        "As the ushers come forward, remember God loves a cheerful giver. You can give online or use the envelopes in front of you.",
        "If you've never given your life to Jesus, today can be that day. With every head bowed, if you want to receive Christ, raise your hand.",
        "Now may the Lord bless you and keep you. Go in peace, have a great week, and we'll see you next Sunday.",
    ]
    var previous: ServiceSectionKind?
    for sample in samples {
        let decision = await classifier.classify(sample, previous: previous)
        let keyword = KeywordSectionClassifier.classify(sample)
        print("\(decision.kind) (\(decision.source), \(Int(decision.confidence * 100))%) title=\"\(decision.suggestedTitle)\"  | keywords: \(keyword.kind)")
        previous = decision.kind
    }
    let title = await classifier.sermonTitle(for: samples[3])
    print("sermon title: \(title ?? "nil") \(await classifier.lastError ?? "")")
    let sermon = """
        So what does it mean to wait on the Lord? Abraham waited twenty-five years for the promise of a son. Faith is not passive, church. \
        Faith is trusting God in the waiting room, when nothing seems to be happening and the promise feels far away. God was working in \
        Abraham's waiting, and he is working in yours. And Solomon tells us, trust in the Lord with all your heart, and do not lean on your \
        own understanding. When we wait, we are tempted to take control, to make it happen ourselves, like Abraham did with Hagar. But \
        waiting on God means letting him be God, and trusting his timing more than our own. So this week, when you're tempted to rush ahead, \
        stop and pray. Ask God what he is doing in your waiting.
        """
    do {
        let summary = try await SermonSummarizer().summarize(sermon)
        print("summary title: \(summary.title)")
        summary.keyPoints.forEach { print("  - \($0)") }
        print("takeaway: \(summary.takeaway)")
    } catch {
        print("summary error: \(error)")
    }
    exit(0)
}
// PERF=<bibles dir>: times the detection steps that run for every segment.
if let dir = ProcessInfo.processInfo.environment["PERF"] {
    func time<T>(_ label: String, _ repeats: Int = 1, _ body: () async -> T) async -> T {
        let start = ContinuousClock.now
        var result: T! = nil
        for _ in 0..<repeats { result = await body() }
        let d = (ContinuousClock.now - start) / repeats
        print("\(label): \(d.formatted(.units(allowed: [.milliseconds, .microseconds], width: .narrow)))")
        return result
    }
    let files = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil)
    let translations = await time("open translations") { TranslationLibrary.load(bundled: files, importedDirectory: nil) }
    let detector = ScriptureDetector(translations: translations)
    let segment = "So Solomon tells us, trust in the Lord with all your heart, and do not lean on your own understanding, in all your ways acknowledge him."
    _ = await time("reference parse (per segment)", 200) { detector.references(in: segment + " John 3:16") }
    _ = await time("passage lookup", 200) { await detector.passage(BibleReference(book: "JHN", chapter: 3, verseStart: 16), abbreviation: "KJV") }
    _ = await time("score 5 versions", 50) { await detector.scoreVersions(spoken: segment, reference: BibleReference(book: "PRO", chapter: 3, verseStart: 5, verseEnd: 6)) }
    await time("build quote index") { await detector.prepareQuoteIndex() }
    _ = await time("quote lookup (45-word window)", 20) { await detector.quotedVerses(in: segment) }
    let songsURL = URL(fileURLWithPath: "../../Transcribe/Resources/songs.json")
    let records = try SongImporter.songs(fromJSON: Data(contentsOf: songsURL))
    let big = (0..<70).flatMap { i in records.map { SongRecord(title: "\($0.title) \(i)", artist: $0.artist, sections: $0.sections) } }
    let matcher = await time("build matcher (\(big.count) songs)") { SongMatcher(songs: big) }
    _ = await time("song match (\(big.count) songs)", 50) { matcher.match(text: segment) }
    exit(0)
}
guard arguments.count >= 2 else {
    print("usage: TranscribeSmoke <audio-file> [locale]")
    exit(2)
}
let url = URL(fileURLWithPath: arguments[1])
let locale = Locale(identifier: arguments.count > 2 ? arguments[2] : "en_US")

let file = try AVAudioFile(forReading: url)
let (audio, input) = AsyncStream.makeStream(of: AudioChunk.self)
let startClock = ContinuousClock.now
let transcriber = try await TranscriberFactory.make(locale: locale)
print("engine: \(transcriber.engine.rawValue), factory \(ContinuousClock.now - startClock)")
let events = try await transcriber.start(audio: audio)
print("transcriber ready after \(ContinuousClock.now - startClock)")

let realtime = ProcessInfo.processInfo.environment["REALTIME"] != nil
let clockStart = ContinuousClock.now
func elapsed() -> Double { let d = ContinuousClock.now - clockStart; return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }
let reader = Task {
    var finals: [TranscribedSegment] = []
    for try await event in events {
        if realtime, case .volatile(let text) = event { print(String(format: "  wall %6.2f volatile: %@", elapsed(), text)) }
        if realtime, case .finalized = event { print(String(format: "  wall %6.2f FINAL", elapsed())) }
        switch event {
        case .finalized(let segment, _):
            finals.append(segment)
            print(String(format: "[%6.2f-%6.2f] %@", segment.start, segment.end, segment.text))
        case .status(let message) where !message.isEmpty:
            print("status: \(message)")
        default:
            break
        }
    }
    return finals
}

while file.framePosition < file.length {
    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else { break }
    try file.read(into: buffer, frameCount: 4096)
    input.yield(AudioChunk(buffer: buffer))
    if realtime { try await Task.sleep(for: .seconds(Double(buffer.frameLength) / buffer.format.sampleRate)) }
}
input.finish()
await transcriber.finish()
let finals = try await reader.value
print("segments: \(finals.count)")

// Optional: BIBLES=<dir> runs scripture detection over the transcript.
if let dir = ProcessInfo.processInfo.environment["BIBLES"] {
    let files = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil)
    let detector = ScriptureDetector(translations: TranslationLibrary.load(bundled: files, importedDirectory: nil))
    let transcript = finals.map(\.text).joined(separator: " ")
    for detection in detector.references(in: transcript) {
        let scores = await detector.scoreVersions(spoken: transcript, reference: detection.reference)
        let ranked = scores.prefix(3).map { "\($0.abbreviation) \(Int($0.score * 100))%" }.joined(separator: ", ")
        print("reference: \(detection.reference) (confidence \(detection.confidence)) -> \(ranked)")
    }
    if let named = detector.namedVersion(in: transcript) { print("named version: \(named)") }
    await detector.prepareQuoteIndex()
    for match in await detector.quotedVerses(in: transcript) {
        print("quoted: \(match.reference) -> \(match.best.abbreviation) \(Int(match.best.score * 100))%")
    }
}

// Optional: SONGS=<songs.json> runs song matching over the transcript, segment by segment.
if let path = ProcessInfo.processInfo.environment["SONGS"] {
    let matcher = SongMatcher(songs: try SongImporter.songs(fromJSON: Data(contentsOf: URL(fileURLWithPath: path))))
    var tracker = SongTracker()
    var window: [String] = []
    for segment in finals {
        window = Array((window + TextNormalizer.tokens(segment.text)).suffix(SongMatcher.windowSize))
        let match = matcher.match(window: window)
        let events = tracker.update(match, at: segment.end)
        let label = match.map { "\($0.title) / \($0.sectionName) \(Int($0.confidence * 100))%" } ?? "-"
        print(String(format: "song @%5.1f: %@ %@", segment.end, label, events.isEmpty ? "" : "\(events)"))
    }
    print("end events after 16 s of silence: \(tracker.tick(at: (finals.last?.end ?? 0) + 16))")
}
