import AVFoundation
import Foundation
import Observation
import SwiftData
import Transcriber

/// Where each service's audio is kept: one AAC file per recording run (start, or continue after
/// stopping), named by where it starts in the service.
enum ServiceAudio {
    static var root: URL {
        URL.applicationSupportDirectory.appending(path: "Transcribe/Recordings", directoryHint: .isDirectory)
    }

    static func folder(for id: UUID) -> URL {
        root.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    /// A new file for a run starting `offset` seconds into the service.
    static func newPart(for id: UUID, startingAt offset: TimeInterval) -> URL {
        folder(for: id).appending(path: String(format: "%010.2f-%@.m4a", offset, String(UUID().uuidString.prefix(6))))
    }

    /// The service's audio files in order, with where each starts.
    static func parts(for id: UUID) -> [(offset: TimeInterval, url: URL)] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder(for: id), includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "m4a" }
            .compactMap { url in
                Double(url.deletingPathExtension().lastPathComponent.split(separator: "-").first ?? "").map { ($0, url) }
            }
            .sorted { $0.0 < $1.0 }
    }

    static func hasAudio(for id: UUID) -> Bool { !parts(for: id).isEmpty }

    static func delete(for id: UUID) {
        try? FileManager.default.removeItem(at: folder(for: id))
    }
}

/// Makes the full transcript of a finished service from its saved audio, and slots the phrases in
/// among the scripture cards, songs and headers by time.
@MainActor
@Observable
final class TranscriptGenerator {
    /// Progress (0…1) of services being transcribed, by service id.
    private(set) var progress: [UUID: Double] = [:]
    private(set) var errors: [UUID: String] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]

    func isRunning(_ session: Session) -> Bool { progress[session.id] != nil }

    func cancel(_ session: Session) {
        tasks[session.id]?.cancel()
    }

    func generate(_ session: Session, context: ModelContext) {
        let id = session.id
        guard tasks[id] == nil else { return }
        let parts = ServiceAudio.parts(for: id)
        guard !parts.isEmpty else {
            errors[id] = "This service has no saved audio."
            return
        }
        errors[id] = nil
        progress[id] = 0
        let locale = Locale(identifier: session.localeIdentifier.isEmpty ? Locale.current.identifier : session.localeIdentifier)
        let total = max(1, parts.reduce(0.0) { sum, part in sum + Self.duration(of: part.url) })
        tasks[id] = Task { [weak self] in
            var found: [TranscribedSegment] = []
            var done = 0.0
            do {
                for part in parts {
                    let length = Self.duration(of: part.url)
                    let collector = SegmentCollector()
                    let base = done
                    try await AnalyzerTranscriber.transcribeFile(part.url, locale: locale) { segment in
                        await collector.add(TranscribedSegment(text: segment.text, start: part.offset + segment.start, end: part.offset + segment.end))
                        await MainActor.run { self?.progress[id] = min(0.99, (base + segment.end) / total) }
                    }
                    found += await collector.segments
                    done += length
                    try Task.checkCancellation()
                }
                self?.insert(found, into: session, context: context)
            } catch is CancellationError {
            } catch {
                self?.errors[id] = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            self?.progress[id] = nil
            self?.tasks[id] = nil
        }
    }

    /// Merges the phrases into the service by time, then numbers every item again in order.
    private func insert(_ segments: [TranscribedSegment], into session: Session, context: ModelContext) {
        guard !session.isDeleted, !segments.isEmpty else { return }
        let existing = session.layout.ordered
        var pending = segments.sorted { $0.start < $1.start }[...]
        var order: [TranscriptItem] = []
        order.reserveCapacity(existing.count + segments.count)
        func makeItem(_ segment: TranscribedSegment) -> TranscriptItem {
            let item = TranscriptItem(kind: .segment, sortIndex: 0, timestamp: segment.start)
            item.text = segment.text
            item.endTimestamp = segment.end
            context.insert(item)
            item.session = session
            return item
        }
        for item in existing {
            // Folded items stay with the card they belong to.
            if item.parentItemID == nil {
                while let next = pending.first, next.start < item.timestamp {
                    order.append(makeItem(next))
                    pending.removeFirst()
                }
            }
            order.append(item)
        }
        order += pending.map(makeItem)
        for (index, item) in order.enumerated() { item.sortIndex = Double(index + 1) }
        TranscriptLayout.invalidate(session)
        try? context.save()
    }

    nonisolated static func duration(of url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }
}

private actor SegmentCollector {
    private(set) var segments: [TranscribedSegment] = []
    func add(_ segment: TranscribedSegment) { segments.append(segment) }
}
