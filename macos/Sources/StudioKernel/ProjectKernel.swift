import Foundation

/// Projects contain generic instance definitions; tool configuration stays opaque to the kernel.
public struct Project: Identifiable, Codable, Equatable {
    public let id: UUID
    public let name: String
    public var instances: [AppInstance]
    public var isArchived: Bool

    public init(id: UUID = UUID(), name: String, instances: [AppInstance] = [], isArchived: Bool = false) {
        self.id = id
        self.name = name
        self.instances = instances
        self.isArchived = isArchived
    }
    private enum CodingKeys: String, CodingKey { case id, name, instances, isArchived }
    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        id = try fields.decode(UUID.self, forKey: .id)
        name = try fields.decode(String.self, forKey: .name)
        instances = try fields.decodeIfPresent([AppInstance].self, forKey: .instances) ?? []
        isArchived = try fields.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
    }
}

/// A kernel service boundary; the shell does not read or write workspace files.
public protocol ProjectStore {
    func load() throws -> [Project]
    func save(_ projects: [Project]) throws
}

public enum ProjectCreationError: Error, Equatable, LocalizedError {
    case emptyName
    case duplicateName

    public var errorDescription: String? {
        switch self {
        case .emptyName: return "Enter a project name."
        case .duplicateName: return "A project with this name already exists. Choose another name."
        }
    }
}

/// The microkernel coordinates workspace commands through injected services.
/// Its owner serializes access; the macOS presentation layer uses the main actor.
public final class ProjectKernel {
    private let store: any ProjectStore
    public let plugins: PluginRegistry
    public private(set) var projects: [Project]

    public init(store: any ProjectStore, plugins: PluginRegistry = PluginRegistry()) throws {
        self.store = store
        self.plugins = plugins
        projects = try store.load()
    }

    @discardableResult
    public func createProject(name: String) throws -> Project {
        let name = try validatedProjectName(name)

        let project = Project(name: name)
        let updated = projects + [project]
        // Publish only after durable storage succeeds.
        try store.save(updated)
        projects = updated
        return project
    }

    @discardableResult
    public func renameProject(id: UUID, name: String) throws -> Project {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { throw InstanceError.unknownProject }
        let name = try validatedProjectName(name, excluding: id)
        let renamed = Project(id: id, name: name, instances: projects[index].instances, isArchived: projects[index].isArchived)
        var updated = projects
        updated[index] = renamed
        try store.save(updated)
        projects = updated
        return renamed
    }

    public func setProjectArchived(id: UUID, archived: Bool) throws {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { throw InstanceError.unknownProject }
        guard projects[index].isArchived != archived else { return }
        var updated = projects
        updated[index].isArchived = archived
        try store.save(updated)
        projects = updated
    }

    public func deleteProject(id: UUID) throws {
        guard projects.contains(where: { $0.id == id }) else { throw InstanceError.unknownProject }
        let updated = projects.filter { $0.id != id }
        try store.save(updated)
        projects = updated
    }

    private func validatedProjectName(_ name: String, excluding: UUID? = nil) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ProjectCreationError.emptyName }
        guard !projects.contains(where: {
            $0.id != excluding && $0.name.compare(name, options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")) == .orderedSame
        }) else { throw ProjectCreationError.duplicateName }
        return name
    }

    @discardableResult
    public func createInstance(projectID: UUID, appTypeID: String, name: String, configuration: Data) throws -> AppInstance {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { throw InstanceError.unknownProject }
        let name = try validatedInstanceName(name, in: projects[index], appTypeID: appTypeID)
        try plugins.validate(appTypeID: appTypeID, configuration: configuration)
        let instance = AppInstance(appTypeID: appTypeID, name: name, configuration: configuration)
        var updated = projects
        updated[index].instances.append(instance)
        try store.save(updated)
        projects = updated
        return instance
    }

    public func updateInstance(id: UUID, name: String, configuration: Data) throws {
        guard let p = projects.firstIndex(where: { $0.instances.contains { $0.id == id } }),
              let i = projects[p].instances.firstIndex(where: { $0.id == id }) else { throw InstanceError.unknownInstance }
        let original = projects[p].instances[i]
        let name = try validatedInstanceName(name, in: projects[p], appTypeID: original.appTypeID, excluding: id)
        try plugins.validate(appTypeID: original.appTypeID, configuration: configuration)
        var updated = projects
        updated[p].instances[i] = AppInstance(id: id, appTypeID: original.appTypeID, name: name, configuration: configuration)
        try store.save(updated)
        projects = updated
    }

    public func deleteInstance(id: UUID) throws {
        guard let p = projects.firstIndex(where: { $0.instances.contains { $0.id == id } }) else { throw InstanceError.unknownInstance }
        var updated = projects
        updated[p].instances.removeAll { $0.id == id }
        try store.save(updated)
        projects = updated
    }

    private func validatedInstanceName(_ name: String, in project: Project, appTypeID: String, excluding: UUID? = nil) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw InstanceError.emptyName }
        guard !project.instances.contains(where: {
            $0.id != excluding && $0.appTypeID == appTypeID && $0.name.compare(name, options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")) == .orderedSame
        }) else { throw InstanceError.duplicateName }
        return name
    }

}
