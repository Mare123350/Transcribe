import SwiftData
import SwiftUI

/// Three panes: sessions, the live transcript, and an inspector for jumping to songs, verses, and headers.
struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SessionListView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 340)
        } detail: {
            if let session = model.selectedSession {
                TranscriptView(session: session)
                    .id(session.id)
            } else {
                ContentUnavailableView {
                    Label("No Session Selected", systemImage: "waveform")
                } description: {
                    Text("Press Record (⌘R) to start transcribing a service, or pick a session from the sidebar.")
                } actions: {
                    Button("Record") { Task { await model.toggleRecording() } }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .inspector(isPresented: $model.showInspector) {
            Group {
                if let session = model.selectedSession {
                    InspectorView(session: session)
                } else {
                    ContentUnavailableView("Nothing to Show", systemImage: "sidebar.right")
                }
            }
            .inspectorColumnWidth(min: 240, ideal: 280, max: 400)
        }
        .toolbar { RecordingToolbar() }
        #if DEBUG
        .onAppear { LaunchTiming.windowAppeared(model) }
        #endif
        .sheet(isPresented: $model.isExporting) {
            if let session = model.selectedSession {
                ExportSheet(session: session)
            }
        }
        .sheet(isPresented: $model.isInsertingVerse) {
            if let session = model.selectedSession {
                InsertVerseSheet(session: session)
            }
        }
        .alert(
            model.recorder.problem?.title ?? "",
            isPresented: Binding(get: { model.recorder.problem != nil }, set: { if !$0 { model.recorder.problem = nil } }),
            presenting: model.recorder.problem
        ) { problem in
            Button("Open System Settings") { problem.openSettings() }
            Button("Cancel", role: .cancel) {}
        } message: { problem in
            Text(problem.message)
        }
        .alert(
            "Recording Problem",
            isPresented: Binding(get: { model.recorder.errorMessage != nil }, set: { if !$0 { model.recorder.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.recorder.errorMessage ?? "")
        }
    }
}
