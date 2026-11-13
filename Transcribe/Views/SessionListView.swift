import SwiftData
import SwiftUI

struct SessionListView: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \Session.createdAt, order: .reverse) private var sessions: [Session]
    @State private var renaming: Session?

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedSession) {
            ForEach(sessions) { session in
                SessionRow(session: session, isRenaming: renaming === session) { renaming = nil }
                    .tag(session)
                    .contextMenu {
                        Button("Rename") { renaming = session }
                        Divider()
                        Button("Delete", role: .destructive) { model.delete(session) }
                            .disabled(model.recorder.isActive && model.recorder.session === session)
                    }
            }
        }
        .overlay {
            if sessions.isEmpty {
                ContentUnavailableView("No Sessions", systemImage: "list.bullet.rectangle", description: Text("Recorded services appear here."))
            }
        }
        .toolbar {
            ToolbarItem {
                Button { model.newSession() } label: { Label("New Session", systemImage: "square.and.pencil") }
                    .help("New session (⇧⌘N)")
            }
        }
    }
}

private struct SessionRow: View {
    @Bindable var session: Session
    let isRenaming: Bool
    let onCommit: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if model.recorder.session === session && model.recorder.isActive {
                    Image(systemName: model.recorder.state == .paused ? "pause.circle.fill" : "record.circle")
                        .foregroundStyle(.red)
                        .symbolEffect(.pulse, isActive: model.recorder.state == .recording)
                }
                if isRenaming {
                    TextField("Title", text: $session.title)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(onCommit)
                } else {
                    Text(session.title.isEmpty ? "Untitled" : session.title)
                        .lineLimit(2)
                }
            }
            Text("\(session.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(TimeFormat.clock(session.duration))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
