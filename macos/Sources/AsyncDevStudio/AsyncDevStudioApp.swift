import AppKit
import SwiftUI
import StudioKernel
import StudioPresentation
import TerminalPlugin
import ClaudePlugin
import CodexPlugin
import BrowserPlugin
import TeamsPlugin
import EditorPlugin
import ImagePlugin
import StudioPlatform

@main
struct AsyncDevStudioApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var delegate
    @StateObject private var application = ApplicationModel()
    @AppStorage("showArchivedProjects") private var showArchivedProjects = false

    var body: some Scene {
        WindowGroup("Async Dev Studio") {
            Group {
                if let workspace = application.workspace {
                    WorkspaceView(model: workspace, terminals: application.terminals, browsers: application.browsers, editors: application.editors, images: application.images)
                        .onAppear { delegate.workspace = workspace }
                        .onChange(of: showArchivedProjects, initial: true) { _, value in
                            workspace.showArchivedProjects = value
                        }
                } else {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                        Text("Couldn’t open projects").font(.title2)
                        Text(application.startupError ?? "Please try again.")
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Button("Try Again", action: application.load)
                    }
                    .padding(32)
                }
            }
            .frame(minWidth: 700, minHeight: 440)
            .onAppear { delegate.terminals = application.terminals; delegate.browsers = application.browsers; delegate.editors = application.editors; delegate.workspace = application.workspace }
        }
        .defaultSize(width: 960, height: 640)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project…") { application.workspace?.beginCreatingProject() }
                    .keyboardShortcut("n")
                    .disabled(application.workspace == nil)
                Button("Restart", action: delegate.restart)
                Divider()
                Toggle("Show Archived Project", isOn: $showArchivedProjects)
            }
        }
    }
}

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    var terminals: TerminalRuntime?
    var browsers: BrowserRuntime?
    var editors: EditorRuntime?
    var workspace: WorkspaceModel?
    private let restartCoordinator = RestartCoordinator()
    private var terminationInProgress = false

    func restart() {
        guard !terminationInProgress, workspace?.isDeletingProject != true else { return }
        restartCoordinator.request()
        NSApplication.shared.terminate(nil)
    }

    private func cancelTermination() -> NSApplication.TerminateReply {
        restartCoordinator.cancel()
        terminationInProgress = false
        workspace?.isTerminating = false
        return .terminateCancel
    }

    private func completeTermination() -> Bool {
        guard restartCoordinator.isRequested else { return true }
        do {
            try restartCoordinator.scheduleIfRequested(target: RestartTarget.current(), processID: ProcessInfo.processInfo.processIdentifier)
            return true
        } catch {
            _ = cancelTermination()
            let alert = NSAlert()
            alert.messageText = "Couldn’t restart the application"
            alert.informativeText = error.localizedDescription + "\nThe application will remain open."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return false
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if workspace?.isDeletingProject == true {
            restartCoordinator.cancel()
            NSSound.beep()
            return .terminateCancel
        }
        guard !terminationInProgress else { return .terminateLater }
        terminationInProgress = true
        workspace?.isTerminating = true
        do {
            guard try editors?.approveQuit() ?? true else { return cancelTermination() }
        } catch {
            let alert = NSAlert(); alert.messageText = "Couldn’t save editor changes"
            alert.informativeText = error.localizedDescription; alert.addButton(withTitle: "OK"); alert.runModal()
            return cancelTermination()
        }
        if let terminals, terminals.hasRunningSessions {
            let alert = NSAlert()
            alert.messageText = "Quit and stop running terminals?"
            alert.informativeText = "Shells and their running commands will stop. Browser logins and saved configurations will be kept."
            alert.addButton(withTitle: "Quit and Stop")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return cancelTermination() }
        }
        guard terminals?.hasRunningSessions == true || browsers?.controllers.isEmpty == false else {
            return completeTermination() ? .terminateNow : .terminateCancel
        }
        Task { @MainActor in
            do {
                try await browsers?.prepareToQuit()
                terminals?.stopAll()
                while terminals?.hasRunningSessions == true {
                    try? await Task.sleep(nanoseconds: 20_000_000)
                }
                sender.reply(toApplicationShouldTerminate: completeTermination())
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn’t save browser login state"
                alert.informativeText = error.localizedDescription + "\nThe application will remain open. Resolve the problem and try quitting again."
                alert.addButton(withTitle: "OK")
                alert.runModal()
                _ = cancelTermination()
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@MainActor
final class ApplicationModel: ObservableObject {
    let terminals = TerminalRuntime(plugins: [TerminalPlugin(), ClaudePlugin(), CodexPlugin()])
    let editors = EditorRuntime()
    let images = ImageRuntime()
    let browsers = BrowserRuntime(directory: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/AsyncDevStudio/BrowserNavigation"), plugins: [BrowserPlugin(), TeamsPlugin()])
    @Published private(set) var workspace: WorkspaceModel?
    @Published private(set) var startupError: String?

    init() { load() }

    func load() {
        do {
            let base = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let file = base.appendingPathComponent("AsyncDevStudio/projects.json")
            let plugins = PluginRegistry()
            try plugins.register(TerminalPlugin())
            try plugins.register(ClaudePlugin())
            try plugins.register(CodexPlugin())
            try plugins.register(BrowserPlugin())
            try plugins.register(TeamsPlugin())
            try plugins.register(EditorPlugin())
            try plugins.register(ImagePlugin())
            workspace = WorkspaceModel(kernel: try ProjectKernel(store: JSONProjectStore(fileURL: file), plugins: plugins))
            startupError = nil
        } catch {
            workspace = nil
            startupError = error.localizedDescription
        }
    }
}

struct WorkspaceView: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var terminals: TerminalRuntime
    @ObservedObject var browsers: BrowserRuntime
    @ObservedObject var editors: EditorRuntime
    @ObservedObject var images: ImageRuntime
    @State private var editing: TerminalEditRequest?
    @State private var editingBrowser: BrowserEditRequest?
    @State private var editingEditor: EditorEditRequest?
    @State private var editingImage: ImageEditRequest?
    @State private var actionError: String?
    @State private var renamingProject: Project?

    var body: some View {
        NavigationSplitView {
            List {
                Section("Projects") {
                    ForEach(model.visibleProjects) { project in
                        DisclosureGroup {
                            ForEach(project.instances) { instance in
                                Button { open(instance) } label: {
                                    Label { Text(instance.name) } icon: { instanceIcon(instance) }
                                        .foregroundStyle(model.selectedProjectID == project.id && model.selectedInstanceID == instance.id ? Color.accentColor : Color.primary)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("Open") { open(instance) }
                                    Button("Configure…") { configure(instance, projectID: project.id) }
                                    Button("Delete…", role: .destructive) { delete(instance) }
                                }
                            }
                        } label: {
                            Button {
                                model.selectedProjectID = project.id
                            } label: {
                                Label(project.name, systemImage: project.isArchived ? "archivebox" : "folder")
                                    .foregroundStyle(model.selectedProjectID == project.id ? Color.accentColor : Color.primary)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Rename…") { renamingProject = project }
                                Button(project.isArchived ? "Restore" : "Archive") {
                                    do { try model.setProjectArchived(id: project.id, archived: !project.isArchived) }
                                    catch { actionError = error.localizedDescription }
                                }
                                Divider()
                                Button("Add Terminal…") { editing = TerminalEditRequest(projectID: project.id, instance: nil) }
                                Button("Add Claude…") { editing = TerminalEditRequest(projectID: project.id, instance: nil, plugin: ClaudePlugin()) }
                                Button("Add Codex…") { editing = TerminalEditRequest(projectID: project.id, instance: nil, plugin: CodexPlugin()) }
                                Button("Add Browser…") { editingBrowser = BrowserEditRequest(projectID: project.id, instance: nil) }
                                Button("Add Teams…") { editingBrowser = BrowserEditRequest(projectID: project.id, instance: nil, plugin: TeamsPlugin()) }
                                Button("Add Text Editor…") { editingEditor = EditorEditRequest(projectID: project.id, instance: nil) }
                                Button("Add Image Viewer…") { editingImage = ImageEditRequest(projectID: project.id, instance: nil) }
                                Divider()
                                Button("Delete…", role: .destructive) { deleteProject(project) }
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                MemoryUsageLabel()
                    .background(.bar)
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 270)
        } detail: {
            if let project = model.selectedProject {
                VStack(spacing: 0) {
                    if !model.openInstances.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 4) {
                                ForEach(model.openInstances) { instance in
                                    HStack(spacing: 8) {
                                        Button(instance.name) { model.openInstance(instance.id) }.buttonStyle(.plain)
                                        Button { close(instance) } label: { Image(systemName: "xmark").font(.caption) }
                                            .buttonStyle(.plain).help(browsers.plugin(for: instance.appTypeID) != nil ? "Close browser and keep login profile" : (instance.appTypeID == "editor" ? "Close editor" : (instance.appTypeID == "images" ? "Close image viewer" : "Close and stop terminal")))
                                    }
                                    .padding(10)
                                    .background(model.selectedInstanceID == instance.id ? Color.accentColor.opacity(0.16) : Color.clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .contextMenu {
                                        Button("Configure…") { configure(instance, projectID: project.id) }
                                        if terminals.plugin(for: instance.appTypeID) != nil { Button("Stop…") { stop(instance) } }
                                    }
                                }
                            }
                            .padding(6)
                        }
                        Divider()
                    }
                    if let id = model.selectedInstanceID, let controller = terminals.controllers[id] {
                        TerminalPane(controller: controller).id(id)
                    } else if let id = model.selectedInstanceID, let controller = browsers.controllers[id] {
                        BrowserPane(controller: controller).id(id)
                    } else if let id = model.selectedInstanceID, let workspace = images.controllers[id] {
                        ImagePane(workspace: workspace).id(id)
                    } else if let id = model.selectedInstanceID, let workspace = editors.controllers[id] {
                        EditorPane(workspace: workspace).id(id)
                    } else {
                        VStack(spacing: 16) {
                            Image(systemName: "folder").font(.system(size: 44)).foregroundStyle(.secondary)
                            Text(project.name).font(.largeTitle).textSelection(.enabled)
                            VStack(spacing: 8) {
                                HStack {
                                    Button("Add Terminal…") { editing = TerminalEditRequest(projectID: project.id, instance: nil) }
                                    Button("Add Claude…") { editing = TerminalEditRequest(projectID: project.id, instance: nil, plugin: ClaudePlugin()) }
                                    Button("Add Codex…") { editing = TerminalEditRequest(projectID: project.id, instance: nil, plugin: CodexPlugin()) }
                                    Button("Add Browser…") { editingBrowser = BrowserEditRequest(projectID: project.id, instance: nil) }
                                }
                                HStack {
                                    Button("Add Teams…") { editingBrowser = BrowserEditRequest(projectID: project.id, instance: nil, plugin: TeamsPlugin()) }
                                    Button("Add Text Editor…") { editingEditor = EditorEditRequest(projectID: project.id, instance: nil) }
                                    Button("Add Image Viewer…") { editingImage = ImageEditRequest(projectID: project.id, instance: nil) }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "folder.badge.plus").font(.system(size: 44)).foregroundStyle(.secondary)
                    Text(model.projects.isEmpty ? "Create your first project" : (model.visibleProjects.isEmpty ? "All projects are archived" : "Select a project")).font(.title2)
                    if !model.projects.isEmpty && model.visibleProjects.isEmpty {
                        Text("Choose File → Show Archived Project to view them.").foregroundStyle(.secondary)
                    }
                    Button("Create Project", action: model.beginCreatingProject).buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(model.selectedProject?.name ?? "Async Dev Studio")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(model.selectedProject?.name ?? "Async Dev Studio")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(model.selectedProject?.name ?? "Async Dev Studio")
                    .accessibilityAddTraits(.isHeader)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: model.beginCreatingProject) { Label("Create Project", systemImage: "plus") }
                    .help("Create a project (⌘N)")
                Button {
                    if let id = model.selectedProjectID { editing = TerminalEditRequest(projectID: id, instance: nil) }
                } label: { Label("Add Terminal", systemImage: "terminal") }
                    .disabled(model.selectedProjectID == nil)
                Button {
                    if let id = model.selectedProjectID { editing = TerminalEditRequest(projectID: id, instance: nil, plugin: ClaudePlugin()) }
                } label: { Label("Add Claude", systemImage: "sparkles") }
                    .disabled(model.selectedProjectID == nil)
                Button {
                    if let id = model.selectedProjectID { editing = TerminalEditRequest(projectID: id, instance: nil, plugin: CodexPlugin()) }
                } label: { Label("Add Codex", systemImage: "chevron.left.forwardslash.chevron.right") }
                    .disabled(model.selectedProjectID == nil)
                Button {
                    if let id = model.selectedProjectID { editingBrowser = BrowserEditRequest(projectID: id, instance: nil) }
                } label: { Label("Add Browser", systemImage: "globe") }
                    .disabled(model.selectedProjectID == nil)
                Button {
                    if let id = model.selectedProjectID { editingBrowser = BrowserEditRequest(projectID: id, instance: nil, plugin: TeamsPlugin()) }
                } label: { Label { Text("Add Teams") } icon: { TeamsIcon() } }
                    .disabled(model.selectedProjectID == nil)
                Button {
                    if let id = model.selectedProjectID { editingEditor = EditorEditRequest(projectID: id, instance: nil) }
                } label: { Label("Add Text Editor", systemImage: "doc.text") }
                    .disabled(model.selectedProjectID == nil)
                Button {
                    if let id = model.selectedProjectID { editingImage = ImageEditRequest(projectID: id, instance: nil) }
                } label: { Label("Add Image Viewer", systemImage: "photo.on.rectangle") }
                    .disabled(model.selectedProjectID == nil)
            }
        }
        .disabled(model.isDeletingProject || model.isTerminating)
        .overlay {
            if model.isDeletingProject {
                ProgressView("Deleting project…")
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .sheet(item: $renamingProject) { project in
            RenameProjectView(model: model, project: project)
        }
        .sheet(isPresented: $model.isCreatingProject, onDismiss: model.cancelCreatingProject) {
            CreateProjectView(model: model)
        }
        .sheet(item: $editing) { request in
            TerminalConfigurationView(request: request) { name, data in
                if let instance = request.instance {
                    try model.updateInstance(id: instance.id, name: name, configuration: data)
                    try terminals.configure(AppInstance(id: instance.id, appTypeID: instance.appTypeID, name: name, configuration: data))
                } else {
                    _ = try model.createInstance(projectID: request.projectID, appTypeID: request.plugin.descriptor.id, name: name, configuration: data)
                }
            }
        }
        .sheet(item: $editingBrowser) { request in
            BrowserConfigurationView(request: request) { name, configuration in
                if let instance = request.instance {
                    try model.updateInstance(id: instance.id, name: name, configuration: configuration.encoded())
                } else {
                    _ = try model.createInstance(projectID: request.projectID, appTypeID: request.plugin.descriptor.id, name: name, configuration: configuration.encoded())
                }
            }
        }
        .sheet(item: $editingImage) { request in
            ImageConfigurationView(request: request) { name, configuration in
                if let instance = request.instance {
                    let folder = URL(fileURLWithPath: configuration.folder).standardizedFileURL.resolvingSymlinksInPath()
                    let changingFolder = images.controllers[instance.id].map { $0.root != folder } ?? false
                    try model.updateInstance(id: instance.id, name: name, configuration: configuration.encoded())
                    if changingFolder { images.close(instance.id); model.closeInstance(instance.id) }
                } else {
                    _ = try model.createInstance(projectID: request.projectID, appTypeID: "images", name: name, configuration: configuration.encoded())
                }
            }
        }
        .sheet(item: $editingEditor) { request in
            EditorConfigurationView(request: request) { name, configuration in
                if let instance = request.instance {
                    let folder = URL(fileURLWithPath: configuration.folder).standardizedFileURL.resolvingSymlinksInPath()
                    let changingFolder = editors.controllers[instance.id].map { $0.root != folder } ?? false
                    if changingFolder, try !editors.approveClose(instance.id) { throw EditorActionCancelled() }
                    try model.updateInstance(id: instance.id, name: name, configuration: configuration.encoded())
                    if changingFolder { editors.closeApproved(instance.id); model.closeInstance(instance.id) }
                } else {
                    _ = try model.createInstance(projectID: request.projectID, appTypeID: "editor", name: name, configuration: configuration.encoded())
                }
            }
        }
        .alert("Couldn’t complete action", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK") { actionError = nil }
        } message: { Text(actionError ?? "") }
    }

    private func deleteProject(_ project: Project) {
        guard !model.isDeletingProject, !model.isTerminating else { return }
        let running = project.instances.filter { terminals.controllers[$0.id]?.session.processID != nil }
        let alert = NSAlert()
        alert.messageText = "Delete \(project.name)?"
        var detail = "This removes the project and its \(project.instances.count) instance definitions, including saved browser profiles and remembered logins. Source files and editor folders will be kept."
        if !running.isEmpty {
            detail += "\n\nRunning terminals will stop: " + running.map(\.name).joined(separator: ", ") + "."
        }
        detail += "\n\nYou’ll be asked to save any modified editor files."
        alert.informativeText = detail
        alert.addButton(withTitle: running.isEmpty ? "Delete" : "Delete and Stop")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        model.isDeletingProject = true
        Task { @MainActor in
            defer { model.isDeletingProject = false }
            do {
                // Approval does not discard buffers or stop resources before storage commits.
                for instance in project.instances where instance.appTypeID == "editor" {
                    guard try editors.approveClose(instance.id) else { return }
                }
                for instance in project.instances where browsers.plugin(for: instance.appTypeID) != nil {
                    try await browsers.controllers[instance.id]?.checkpoint()
                }
                let terminalControllers = project.instances.compactMap { terminals.controllers[$0.id] }
                try model.deleteProject(id: project.id)
                for instance in project.instances {
                    if instance.appTypeID == "editor" { editors.closeApproved(instance.id) }
                    if instance.appTypeID == "images" { images.close(instance.id) }
                    if terminals.plugin(for: instance.appTypeID) != nil { terminals.close(instance.id) }
                }
                var cleanupErrors: [String] = []
                for instance in project.instances where browsers.plugin(for: instance.appTypeID) != nil {
                    do { try await browsers.deleteProfile(instance.id) }
                    catch { cleanupErrors.append(instance.name + ": " + error.localizedDescription) }
                }
                for controller in terminalControllers {
                    while controller.session.processID != nil { try? await Task.sleep(nanoseconds: 20_000_000) }
                }
                if !cleanupErrors.isEmpty {
                    actionError = "The project was deleted, but these browser profiles could not be fully removed:\n" + cleanupErrors.joined(separator: "\n")
                }
            } catch { actionError = error.localizedDescription }
        }
    }

    @ViewBuilder private func instanceIcon(_ instance: AppInstance) -> some View {
        switch instance.appTypeID {
        case "terminal": Image(systemName: "terminal")
        case "claude": Image(systemName: "sparkles")
        case "codex": Image(systemName: "chevron.left.forwardslash.chevron.right")
        case "browser": Image(systemName: "globe")
        case "teams": TeamsIcon()
        case "editor": Image(systemName: "doc.text")
        case "images": Image(systemName: "photo.on.rectangle")
        default: Image(systemName: "app")
        }
    }

    private func open(_ instance: AppInstance) {
        do {
            if browsers.plugin(for: instance.appTypeID) != nil { try browsers.open(instance) }
            else if instance.appTypeID == "editor" { try editors.open(instance) }
            else if instance.appTypeID == "images" { try images.open(instance) }
            else { try terminals.open(instance) }
            model.openInstance(instance.id)
        } catch { actionError = error.localizedDescription }
    }
    private func configure(_ instance: AppInstance, projectID: UUID) {
        if let plugin = browsers.plugin(for: instance.appTypeID) { editingBrowser = BrowserEditRequest(projectID: projectID, instance: instance, plugin: plugin) }
        else if instance.appTypeID == "editor" { editingEditor = EditorEditRequest(projectID: projectID, instance: instance) }
        else if instance.appTypeID == "images" { editingImage = ImageEditRequest(projectID: projectID, instance: instance) }
        else if let plugin = terminals.plugin(for: instance.appTypeID) { editing = TerminalEditRequest(projectID: projectID, instance: instance, plugin: plugin) }
    }
    private func confirmStop(_ instance: AppInstance, title: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "This will stop the shell and its running commands."
        alert.addButton(withTitle: "Stop")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
    private func close(_ instance: AppInstance) {
        if instance.appTypeID == "images" { images.close(instance.id); model.closeInstance(instance.id); return }
        if instance.appTypeID == "editor" {
            do {
                guard try editors.approveClose(instance.id) else { return }
                editors.closeApproved(instance.id); model.closeInstance(instance.id)
            } catch { actionError = error.localizedDescription }
            return
        }
        if browsers.plugin(for: instance.appTypeID) != nil {
            Task { @MainActor in
                do { try await browsers.close(instance.id); model.closeInstance(instance.id) }
                catch { actionError = error.localizedDescription }
            }
            return
        }
        if terminals.controllers[instance.id]?.session.processID != nil && !confirmStop(instance, title: "Close \(instance.name)?") { return }
        terminals.close(instance.id)
        model.closeInstance(instance.id)
    }
    private func stop(_ instance: AppInstance) {
        guard let controller = terminals.controllers[instance.id], controller.session.processID != nil else { return }
        if confirmStop(instance, title: "Stop \(instance.name)?") { controller.session.stop() }
    }
    private func delete(_ instance: AppInstance) {
        let alert = NSAlert()
        alert.messageText = "Delete \(instance.name)?"
        alert.informativeText = browsers.plugin(for: instance.appTypeID) != nil
            ? "Its saved configuration, browser profile, and remembered logins will be removed."
            : (["editor", "images"].contains(instance.appTypeID) ? "Its saved configuration will be deleted. Files in its folder will be kept." : "Its saved configuration will be deleted and any running shell will stop.")
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if instance.appTypeID == "images" {
            do { try model.deleteInstance(id: instance.id); images.close(instance.id) }
            catch { actionError = error.localizedDescription }
        } else if instance.appTypeID == "editor" {
            do {
                guard try editors.approveClose(instance.id) else { return }
                try model.deleteInstance(id: instance.id); editors.closeApproved(instance.id)
            } catch { actionError = error.localizedDescription }
        } else if browsers.plugin(for: instance.appTypeID) != nil {
            Task { @MainActor in
                do {
                    try model.deleteInstance(id: instance.id)
                    do { try await browsers.deleteProfile(instance.id) }
                    catch { actionError = "The browser definition was deleted, but its saved profile could not be fully removed: " + error.localizedDescription }
                } catch { actionError = error.localizedDescription }
            }
        } else {
            do { try model.deleteInstance(id: instance.id); terminals.close(instance.id) }
            catch { actionError = error.localizedDescription }
        }
    }
}

struct CreateProjectView: View {
    @ObservedObject var model: WorkspaceModel
    @FocusState private var nameIsFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Create Project").font(.title2).fontWeight(.semibold)
            Form {
                TextField("Project name", text: $model.draftName)
                    .focused($nameIsFocused)
                    .onSubmit(model.createProject)
                    .accessibilityIdentifier("projectName")
            }
            if let error = model.creationError {
                Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("creationError")
            }
            HStack {
                Spacer()
                Button("Cancel", action: model.cancelCreatingProject)
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: model.createProject)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("createProject")
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear { nameIsFocused = true }
    }
}
