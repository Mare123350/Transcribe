#if DEBUG
import AppKit
import Foundation

/// Debug-only: launch with `-LiveSelfTest` to record from the real input for ~25 seconds (play
/// speech near the microphone meanwhile), then write timings and the transcript to the app's
/// temporary folder and quit. Measures recording start time and how often partial text arrives.
@MainActor
enum LiveSelfTest {
    static var isRequested: Bool { CommandLine.arguments.contains("-LiveSelfTest") }

    static func run(_ model: AppModel) async {
        try? await Task.sleep(for: .seconds(2))
        var lines: [String] = []
        let clock = ContinuousClock()

        await model.toggleRecording()
        guard model.recorder.state == .recording else {
            lines.append("FAILED to start: \(model.recorder.errorMessage ?? String(describing: model.recorder.problem))")
            finish(lines)
            return
        }
        let recordingStarted = clock.now
        lines.append("start: \(model.recorder.lastStartDuration.map { "\($0)" } ?? "?")")
        for (phase, duration) in model.recorder.lastStartPhases { lines.append("  \(phase): \(duration)") }

        var previous = ""
        var updates: [Duration] = []
        var lastUpdate: ContinuousClock.Instant?
        var firstVolatile: Duration?
        var lastTick = clock.now
        var maxGap = Duration.zero
        var segmentsSeen: [(Duration, String)] = []
        var seenCount = 0
        while clock.now - recordingStarted < .seconds(25) {
            let tick = clock.now
            maxGap = max(maxGap, tick - lastTick)
            lastTick = tick
            let items = model.selectedSession?.orderedItems.filter { $0.kind == .segment } ?? []
            if items.count > seenCount {
                for item in items[seenCount...] { segmentsSeen.append((tick - recordingStarted, item.text)) }
                seenCount = items.count
            }
            let text = model.recorder.volatileText
            if text != previous {
                let now = clock.now
                if !text.isEmpty, firstVolatile == nil { firstVolatile = now - recordingStarted }
                if let lastUpdate, !text.isEmpty { updates.append(now - lastUpdate) }
                lastUpdate = now
                previous = text
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        let stopStarted = clock.now
        await model.stopRecording()
        lines.append("stop: \(clock.now - stopStarted)")
        lines.append("first partial text after: \(firstVolatile.map { "\($0)" } ?? "none")")
        lines.append("longest main-thread gap while polling every 20 ms: \(maxGap)")
        for (time, text) in segmentsSeen { lines.append("  final at \(time): \(text)") }
        let seconds = updates.map { Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18 }.sorted()
        if !seconds.isEmpty {
            lines.append(String(format: "partial updates: %d, median gap %.2fs, 90th %.2fs, max %.2fs",
                                seconds.count, seconds[seconds.count / 2], seconds[seconds.count * 9 / 10], seconds.last!))
        }
        let items = model.selectedSession?.orderedItems ?? []
        lines.append("transcript:")
        for item in items { lines.append("  [\(item.kindRaw)] \(item.kind == .verse ? item.reference + " " + item.versionAbbreviation : item.text)") }
        if let session = model.selectedSession { model.delete(session) }
        finish(lines)
    }

    private static func finish(_ lines: [String]) {
        let url = URL.temporaryDirectory.appending(path: "live-self-test.txt")
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        print("LIVETEST_OUTPUT \(url.path)")
        exit(0)
    }
}
#endif
