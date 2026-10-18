import AppKit
import SwiftUI
import StudioKernel
import EditorPlugin

struct EditorEditRequest: Identifiable {
    let id = UUID()
    let projectID: UUID
    let instance: AppInstance?
}
struct EditorActionCancelled: Error {}
struct EditorConfigurationView: View {
    let request: EditorEditRequest
    let save: (String, EditorConfiguration) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var folder: String
    @State private var error: String?
    @FocusState private var focused: Bool
    init(request: EditorEditRequest, save: @escaping (String, EditorConfiguration) throws -> Void) {
        self.request = request; self.save = save
        let config = request.instance.flatMap { try? EditorConfiguration.decode($0.configuration) } ?? EditorConfiguration()
        _name = State(initialValue: request.instance?.name ?? "")
        _folder = State(initialValue: config.folder)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(request.instance == nil ? "Add Text Editor" : "Configure Text Editor").font(.title2).fontWeight(.semibold)
            Form {
                TextField("Name", text: $name).focused($focused)
                HStack {
                    TextField("Folder", text: $folder)
                    Button("Choose…") {
                        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
                    }
                }
            }
            Text("Browse this folder and edit its text files in separate tabs. Changing the folder closes the current editor after resolving unsaved changes.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(request.instance == nil ? "Add" : "Save") {
                    do {
                        let config = EditorConfiguration(folder: folder)
                        try config.validate(); try save(name, config); dismiss()
                    } catch is EditorActionCancelled { }
                    catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 540).onAppear { focused = true }
    }
}
