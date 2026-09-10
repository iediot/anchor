import AppKit
import SwiftUI

// temporary, and labelled as temporary in the interface
// it exists to separate the launch from the stages that normally follow it, for one
// unresolved crash, and it belongs to the diagnostics window rather than the panel
struct LaunchDiagnosticsView: View {
    @Bindable var model: SavedStatesModel
    @State private var project: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PyCharm launch isolation (temporary diagnostic)").font(.headline)
            Text("""
                 Anchor has never established why PyCharm crashes after it is opened this way. \
                 Each mode below adds one stage to the same launch, so a run that crashes says which \
                 stage was involved. Use a disposable project, and close PyCharm by hand after every run. \
                 Anchor never closes or quits it for you.
                 """)
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button("Choose Project…") { chooseProject() }
                    .disabled(model.busy)
                Text(project ?? "no project chosen")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            ForEach(LaunchDiagnosticMode.allCases) { mode in
                HStack(alignment: .top, spacing: 10) {
                    Button(mode.label) {
                        guard let project else { return }
                        model.requestLaunchDiagnostic(mode, projectPath: project)
                    }
                    .disabled(project == nil || model.busy)
                    .frame(width: 210, alignment: .leading)
                    Text(mode.detail).font(.caption).foregroundStyle(.secondary)
                }
            }

            if model.launch.isRunning {
                Label("running, leave PyCharm alone until it finishes", systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !model.launch.stages.isEmpty {
                Divider()
                HStack {
                    Text(model.launch.mode?.label ?? "result").font(.callout).bold()
                    Spacer()
                    Button("Copy Result") { copy() }
                }
                ForEach(model.launch.stages) { stage in
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(stage.name)\(stage.duration.map { String(format: " · %.2fs", $0) } ?? "")")
                            .font(.caption)
                        Text(stage.detail).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if let summary = model.launch.summary {
                    Text("outcome: \(summary)").font(.caption).foregroundStyle(.secondary)
                }
                Text("The copied result carries stage names, timings and the project path, and never an environment or any project content.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func chooseProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a disposable project to open in PyCharm"
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        project = url.path
    }

    private func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(model.launch.report, forType: .string)
    }
}
