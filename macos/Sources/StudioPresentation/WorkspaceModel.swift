import Combine
import Foundation
import StudioKernel

/// Presentation state translates native UI actions into microkernel commands.
@MainActor
public final class WorkspaceModel: ObservableObject {
    @Published public private(set) var projects: [Project]
    @Published public var selectedProjectID: UUID?
    @Published public var showArchivedProjects = false {
        didSet { selectVisibleProjectIfNeeded() }
    }
    @Published public var isCreatingProject = false
    @Published public var isDeletingProject = false
    @Published public var isTerminating = false
    @Published public var draftName = ""
    @Published public private(set) var creationError: String?
    @Published private var tabs: [UUID: [UUID]] = [:]
    @Published private var selections: [UUID: UUID] = [:]
    private let kernel: ProjectKernel

    public init(kernel: ProjectKernel) {
        self.kernel = kernel
        projects = kernel.projects
    }

    public var selectedProject: Project? {
        visibleProjects.first { $0.id == selectedProjectID }
    }

    public var visibleProjects: [Project] {
        projects.filter { showArchivedProjects || !$0.isArchived }
    }

    private func selectVisibleProjectIfNeeded() {
        guard let id = selectedProjectID, !visibleProjects.contains(where: { $0.id == id }) else { return }
        selectedProjectID = visibleProjects.first?.id
    }

    public func setProjectArchived(id: UUID, archived: Bool) throws {
        try kernel.setProjectArchived(id: id, archived: archived)
        projects = kernel.projects
        selectVisibleProjectIfNeeded()
    }

    public func beginCreatingProject() {
        guard !isCreatingProject, !isDeletingProject, !isTerminating else { return }
        draftName = ""
        creationError = nil
        isCreatingProject = true
    }

    public func cancelCreatingProject() {
        draftName = ""
        creationError = nil
        isCreatingProject = false
    }

    public func createProject() {
        guard isCreatingProject else { return }
        do {
            let project = try kernel.createProject(name: draftName)
            projects = kernel.projects
            selectedProjectID = project.id
            draftName = ""
            creationError = nil
            isCreatingProject = false
        } catch {
            creationError = error.localizedDescription
        }
    }

    public func renameProject(id: UUID, name: String) throws {
        try kernel.renameProject(id: id, name: name)
        projects = kernel.projects
    }

    public func deleteProject(id: UUID) throws {
        try kernel.deleteProject(id: id)
        tabs.removeValue(forKey: id)
        selections.removeValue(forKey: id)
        projects = kernel.projects
        if selectedProjectID == id { selectedProjectID = visibleProjects.first?.id }
    }

    public var selectedInstanceID: UUID? {
        get { selectedProjectID.flatMap { selections[$0] } }
        set {
            guard let project = selectedProjectID else { return }
            selections[project] = newValue
        }
    }

    public var openInstances: [AppInstance] {
        guard let project = selectedProject else { return [] }
        return (tabs[project.id] ?? []).compactMap { id in project.instances.first { $0.id == id } }
    }

    public func openInstance(_ id: UUID) {
        guard let project = visibleProjects.first(where: { $0.instances.contains { $0.id == id } }) else { return }
        selectedProjectID = project.id
        if !(tabs[project.id] ?? []).contains(id) { tabs[project.id, default: []].append(id) }
        selections[project.id] = id
    }

    public func closeInstance(_ id: UUID) {
        guard let project = projects.first(where: { $0.instances.contains { $0.id == id } }) else { return }
        tabs[project.id]?.removeAll { $0 == id }
        if selections[project.id] == id { selections[project.id] = tabs[project.id]?.last }
    }

    @discardableResult
    public func createInstance(projectID: UUID, appTypeID: String, name: String, configuration: Data) throws -> AppInstance {
        let instance = try kernel.createInstance(projectID: projectID, appTypeID: appTypeID, name: name, configuration: configuration)
        projects = kernel.projects
        return instance
    }

    public func updateInstance(id: UUID, name: String, configuration: Data) throws {
        try kernel.updateInstance(id: id, name: name, configuration: configuration)
        projects = kernel.projects
    }

    public func deleteInstance(id: UUID) throws {
        try kernel.deleteInstance(id: id)
        // Remove tab state before publishing new definitions.
        for projectID in Array(tabs.keys) {
            tabs[projectID]?.removeAll { $0 == id }
            if selections[projectID] == id { selections[projectID] = tabs[projectID]?.last }
        }
        projects = kernel.projects
    }

}
