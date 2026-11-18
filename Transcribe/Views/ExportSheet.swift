import Exporter
import SectionClassifier
import SwiftUI

struct ExportSheet: View {
    let session: Session
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage("exportFormat") private var formatRaw = ExportFormat.pdf.rawValue
    @AppStorage("exportTimestamps") private var includeTimestamps = true
    @AppStorage("exportSummary") private var includeSummary = false
    @State private var working = false
    @State private var errorMessage: String?
    @State private var savedURL: URL?

    private var format: ExportFormat { ExportFormat(rawValue: formatRaw) ?? .pdf }
    private var intelligence: IntelligenceStatus { .current }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.l) {
            Text("Export “\(session.title)”").font(.title2.bold())
            Form {
                Picker("Format", selection: $formatRaw) {
                    ForEach(ExportFormat.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                Toggle("Include timestamps", isOn: $includeTimestamps)
                Toggle("Add a sermon summary with key points and scriptures", isOn: $includeSummary)
                    .disabled(!intelligence.isAvailable)
                if case .unavailable(let reason) = intelligence {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

            Text("Headers, song titles with their lyrics, and verse callouts are kept. Sung transcription is replaced by the song lyrics.")
                .font(.caption).foregroundStyle(.secondary)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(Design.Palette.error).font(.callout)
            }
            if let savedURL {
                HStack {
                    Label("Saved \(savedURL.lastPathComponent)", systemImage: "checkmark.circle").foregroundStyle(Design.Palette.good)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([savedURL]) }
                }
                .font(.callout)
            }

            HStack {
                if working {
                    ProgressView().controlSize(.small)
                    Text(includeSummary ? "Summarizing the sermon on-device…" : "Exporting…").foregroundStyle(.secondary)
                }
                Spacer()
                Button(savedURL == nil ? "Cancel" : "Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Export…") { Task { await export() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working)
            }
        }
        .sheetLayout()
    }

    private func export() async {
        working = true
        errorMessage = nil
        defer { working = false }
        do {
            var summary: ExportSummary?
            if includeSummary && intelligence.isAvailable {
                do {
                    summary = try await ExportService.summary(for: session)
                } catch {
                    errorMessage = "Summary skipped: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
                }
            }
            let document = ExportService.document(for: session, includeTimestamps: includeTimestamps, summary: summary)
            let data = try Exporter.data(for: document, as: format)
            if let url = try ExportService.save(data, format: format, suggestedName: session.title) {
                savedURL = url
            }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
