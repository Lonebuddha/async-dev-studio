import AppKit
import SwiftUI
import StudioKernel
import ImagePlugin
import StudioPlatform

struct ImageEditRequest: Identifiable {
    let id = UUID()
    let projectID: UUID
    let instance: AppInstance?
}
struct ImageConfigurationView: View {
    let request: ImageEditRequest
    let save: (String, ImageConfiguration) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var folder: String
    @State private var error: String?
    @FocusState private var focused: Bool
    init(request: ImageEditRequest, save: @escaping (String, ImageConfiguration) throws -> Void) {
        self.request = request; self.save = save
        let config = request.instance.flatMap { try? ImageConfiguration.decode($0.configuration) } ?? ImageConfiguration()
        _name = State(initialValue: request.instance?.name ?? "")
        _folder = State(initialValue: config.folder)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(request.instance == nil ? "Add Image Viewer" : "Configure Image Viewer").font(.title2).fontWeight(.semibold)
            Form {
                TextField("Name", text: $name).focused($focused)
                HStack {
                    TextField("Folder", text: $folder)
                    DirectoryPickerButton(path: $folder) { error = $0 }
                }
            }
            Text("Browse folders, view image thumbnails, and zoom or pan individual images. Changing the folder resets the current view.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(request.instance == nil ? "Add" : "Save") {
                    do {
                        let config = ImageConfiguration(folder: folder)
                        try config.validate(); try save(name, config); dismiss()
                    } catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 540).onAppear { focused = true }
    }
}
