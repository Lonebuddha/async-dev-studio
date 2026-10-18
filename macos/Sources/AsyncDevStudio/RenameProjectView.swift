import SwiftUI
import StudioKernel
import StudioPresentation

struct RenameProjectView: View {
    @ObservedObject var model: WorkspaceModel
    let project: Project
    @State private var name: String
    @State private var error: String?
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss
    init(model: WorkspaceModel, project: Project) {
        self.model = model; self.project = project
        _name = State(initialValue: project.name)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Rename Project").font(.title2).fontWeight(.semibold)
            TextField("Project name", text: $name).focused($focused).onSubmit(rename)
            if let error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Rename", action: rename).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 420).onAppear { focused = true }
    }
    private func rename() {
        do { try model.renameProject(id: project.id, name: name); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}
