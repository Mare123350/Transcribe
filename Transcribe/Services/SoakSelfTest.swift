#if DEBUG
import AppKit
import Darwin
import Foundation

/// Debug-only long-recording test. Launch with
/// `-SoakSelfTest -AudioFile sermon.m4a -AudioSeconds 10800 -AudioSpeed 4`
/// to record a looped audio file through the real pipeline (recogniser, detection, transcript
/// view, saving) and watch the main thread and memory the whole time. Uses its own store in the
/// SoakTest folder. Writes `soak-self-test.txt` (summary) and `soak-self-test.csv` (per minute)
/// to Application Support/Transcribe/SoakTest, then quits. The audio file goes there too.
@MainActor
enum SoakSelfTest {
    static var isRequested: Bool { CommandLine.arguments.contains("-SoakSelfTest") }

    /// Test files live in Application Support: macOS empties the temporary folder when the disk
    /// is nearly full, which deleted the store in the middle of a run.
    static var folder: URL {
        let url = URL.applicationSupportDirectory.appending(path: "Transcribe/SoakTest", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var storeURL: URL { folder.appending(path: "soak-store.sqlite") }

    static func removeStore() {
        for suffix in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + suffix))
        }
    }

    /// Memory the system charges to the app (what Activity Monitor shows), in MB.
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    static func run(_ model: AppModel) async {
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Soak test")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        while !model.scripture.isQuoteIndexReady { try? await Task.sleep(for: .milliseconds(200)) }
        try? await Task.sleep(for: .seconds(2))
        NSApp.activate()
        NSApp.windows.first { $0.isVisible && $0.canBecomeMain }?.makeKeyAndOrderFront(nil)

        let defaults = UserDefaults.standard
        let audioSeconds = defaults.double(forKey: "AudioSeconds")
        let speed = max(defaults.double(forKey: "AudioSpeed"), 1)
        let clock = ContinuousClock()
        var csv = ["wall_min,audio_min,items,top_level_rows,footprint_mb,max_gap_ms,gaps_over_100ms,gaps_over_250ms"]

        let startFootprint = footprintMB()
        await model.toggleRecording()
        guard model.recorder.state == .recording else {
            finish(["FAILED to start: \(model.recorder.errorMessage ?? String(describing: model.recorder.problem))"], csv: csv)
            return
        }
        let started = clock.now
        var last = clock.now
        var bucketMax = Duration.zero, bucketOver100 = 0, bucketOver250 = 0
        var allGaps: [Double] = []
        var totalOver100 = 0, totalOver250 = 0
        var worst: [(at: Double, ms: Double)] = []
        var footprints: [(min: Double, mb: Double)] = []
        var nextBucket = Duration.seconds(60)

        func milliseconds(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }

        while RecordingController.debugPlayedSeconds == nil {
            try? await Task.sleep(for: .milliseconds(10))
            let now = clock.now
            // A 10 ms sleep that took much longer means the main thread was busy for the rest.
            let gap = now - last - .milliseconds(10)
            last = now
            let ms = milliseconds(gap)
            allGaps.append(ms)
            bucketMax = max(bucketMax, gap)
            if ms > 100 { bucketOver100 += 1; totalOver100 += 1; worst.append((milliseconds(now - started) / 1000, ms)) }
            if ms > 250 { bucketOver250 += 1; totalOver250 += 1 }
            if now - started >= nextBucket {
                nextBucket += .seconds(60)
                let wallMin = milliseconds(now - started) / 60000
                let session = model.recorder.session
                let footprint = footprintMB()
                footprints.append((wallMin, footprint))
                csv.append(String(format: "%.1f,%.1f,%d,%d,%.0f,%.0f,%d,%d", wallMin, model.recorder.currentTime / 60,
                                  session?.items.count ?? 0, session?.layout.rows.count ?? 0, footprint,
                                  milliseconds(bucketMax), bucketOver100, bucketOver250))
                print("SOAK " + csv.last!)
                bucketMax = .zero; bucketOver100 = 0; bucketOver250 = 0
            }
            if now - started > .seconds(audioSeconds / speed + 600) { break }
        }
        let stopStart = clock.now
        await model.stopRecording()
        let stopTime = clock.now - stopStart
        let session = model.recorder.session ?? model.selectedSession

        allGaps.sort()
        func percentile(_ p: Double) -> Double { allGaps.isEmpty ? 0 : allGaps[min(allGaps.count - 1, Int(Double(allGaps.count) * p))] }
        let firstHour = footprints.filter { $0.min >= 5 }.first?.mb ?? startFootprint
        // Cards and headers should read in time order.
        let rowTimes = session?.layout.rows.map(\.item.timestamp) ?? []
        let outOfOrder = zip(rowTimes, rowTimes.dropFirst()).filter { $1 < $0 - 2 }.count
        var lines = [
            "audio: \(Int(audioSeconds / 60)) min at \(speed)x speed; wall time \(String(format: "%.1f", milliseconds(clock.now - started) / 60000)) min",
            "recorded: \(String(format: "%.1f", (session?.duration ?? 0) / 60)) min, \(session?.items.count ?? 0) items, \(session?.layout.rows.count ?? 0) rows shown",
            String(format: "main thread gaps: median %.1f ms, 99th %.1f ms, 99.9th %.1f ms, max %.0f ms", percentile(0.5), percentile(0.99), percentile(0.999), allGaps.last ?? 0),
            "hangs over 100 ms: \(totalOver100); over 250 ms: \(totalOver250)",
            "rows earlier in time than the row above (more than 2 s): \(outOfOrder)",
            String(format: "memory: %.0f MB before recording, %.0f MB at 5 min, %.0f MB at the end, peak %.0f MB",
                   startFootprint, firstHour, footprints.last?.mb ?? 0, footprints.map(\.mb).max() ?? 0),
            "stop took: \(stopTime)",
            "transcript mode: \(model.recorder.mode.title)",
            String(format: "saved audio: %.1f MB", Self.audioSize(session)),
            "worst hangs (wall seconds, ms):",
        ]
        for hang in worst.sorted(by: { $0.ms > $1.ms }).prefix(15) { lines.append(String(format: "  %.0f s: %.0f ms", hang.at, hang.ms)) }
        finish(lines, csv: csv)
    }

    /// Size of the service's saved audio, which is then deleted (the test makes hours of it).
    static func audioSize(_ session: Session?) -> Double {
        guard let session else { return 0 }
        let bytes = ServiceAudio.parts(for: session.id).reduce(0) { sum, part in
            sum + ((try? part.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        ServiceAudio.delete(for: session.id)
        return Double(bytes) / 1_048_576
    }

    static func finish(_ lines: [String], csv: [String]) {
        let summary = folder.appending(path: "soak-self-test.txt")
        try? lines.joined(separator: "\n").write(to: summary, atomically: true, encoding: .utf8)
        try? csv.joined(separator: "\n").write(to: folder.appending(path: "soak-self-test.csv"), atomically: true, encoding: .utf8)
        print("SOAK_OUTPUT \(summary.path)")
        removeStore()
        exit(0)
    }
}
#endif
