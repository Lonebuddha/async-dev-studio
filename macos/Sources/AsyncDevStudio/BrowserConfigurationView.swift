import SwiftUI
import StudioKernel
import BrowserPlugin

struct BrowserEditRequest: Identifiable {
    let id = UUID()
    let projectID: UUID
    let instance: AppInstance?
    let plugin: BrowserPlugin
    init(projectID: UUID, instance: AppInstance?, plugin: BrowserPlugin = BrowserPlugin()) {
        self.projectID = projectID; self.instance = instance; self.plugin = plugin
    }
}
struct BrowserConfigurationView: View {
    let request: BrowserEditRequest
    let save: (String, BrowserConfiguration) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var initialURL: String
    @State private var error: String?
    @FocusState private var nameFocused: Bool
    init(request: BrowserEditRequest, save: @escaping (String, BrowserConfiguration) throws -> Void) {
        self.request = request; self.save = save
        let configuration = request.instance.flatMap { try? BrowserConfiguration.decode($0.configuration) } ?? request.plugin.defaultConfiguration
        _name = State(initialValue: request.instance?.name ?? request.plugin.suggestedInstanceName)
        _initialURL = State(initialValue: configuration.initialURL)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text((request.instance == nil ? "Add " : "Configure ") + request.plugin.descriptor.name).font(.title2).fontWeight(.semibold)
            Form {
                TextField("Name", text: $name).focused($nameFocused)
                TextField("Initial website", text: $initialURL)
            }
            Text("Each instance has its own saved login profile. Closing a tab keeps cookies and website storage. Reopening restores the last visited page.")
                .font(.caption).foregroundStyle(.secondary)
            if request.instance != nil {
                Text("Renaming or changing the initial website keeps the profile. The initial website is used when there is no saved page.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(request.instance == nil ? "Add" : "Save") {
                    do {
                        let url = try BrowserConfiguration.normalizedURL(initialURL)
                        try save(name, BrowserConfiguration(initialURL: url.absoluteString))
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 500).onAppear { nameFocused = true }
    }
}
