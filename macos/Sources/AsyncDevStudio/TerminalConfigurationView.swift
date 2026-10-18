import AppKit
import SwiftUI
import StudioKernel
import TerminalPlugin

struct TerminalEditRequest: Identifiable {
    let id = UUID()
    let projectID: UUID
    let instance: AppInstance?
    var plugin: TerminalAppPlugin = TerminalPlugin()
}

struct TerminalConfigurationView: View {
    let request: TerminalEditRequest
    let save: (String, Data) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var shell: String
    @State private var directory: String
    @State private var commands: String
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    init(request: TerminalEditRequest, save: @escaping (String, Data) throws -> Void) {
        self.request = request
        self.save = save
        let config = request.instance.flatMap { try? request.plugin.decodeConfiguration($0.configuration) } ?? TerminalConfiguration()
        _name = State(initialValue: request.instance?.name ?? (request.plugin.supportsStartupCommands ? "" : request.plugin.descriptor.name))
        _shell = State(initialValue: config.shell)
        _directory = State(initialValue: config.workingDirectory)
        _commands = State(initialValue: config.startupCommands.joined(separator: "\n"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text((request.instance == nil ? "Add " : "Configure ") + request.plugin.descriptor.name)
                .font(.title2).fontWeight(.semibold)
            Form {
                TextField("Name", text: $name).focused($nameFocused)
                TextField("Shell (zsh, bash, or sh)", text: $shell)
                HStack {
                    TextField("Working directory", text: $directory)
                    Button("Choose…", action: chooseDirectory)
                }
            }
            if request.plugin.supportsStartupCommands {
                Text("Startup commands (one per line)").font(.headline)
                TextEditor(text: $commands).font(.system(.body, design: .monospaced))
                    .frame(height: 130).border(Color.secondary.opacity(0.25))
                    .accessibilityLabel("Startup commands")
                Text("Commands run in order when the shell starts. A failing command stops initialization. Put long-running commands last.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let summary = request.plugin.configurationSummary {
                Text(summary)
                    .font(.caption).foregroundStyle(.secondary)
            }
            if request.instance != nil {
                Text("Configuration changes apply the next time the shell starts.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(request.instance == nil ? "Add" : "Save", action: submit)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 540)
        .onAppear { nameFocused = true }
    }

    private func submit() {
        do {
            let data = try request.plugin.configurationData(
                shell: shell.trimmingCharacters(in: .whitespacesAndNewlines),
                workingDirectory: directory.trimmingCharacters(in: .whitespacesAndNewlines),
                startupCommands: commands.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            )
            try save(name, data)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { directory = url.path }
    }
}
