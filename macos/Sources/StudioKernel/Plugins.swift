import Foundation

public struct AppDescriptor: Identifiable, Equatable {
    public let id: String
    public let name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

/// Platform modules register at compile time. The kernel knows no tool-specific fields.
public protocol AppPlugin {
    var descriptor: AppDescriptor { get }
    func validate(configuration: Data) throws
}

public final class PluginRegistry {
    private var plugins: [String: any AppPlugin] = [:]
    public init() {}
    public var descriptors: [AppDescriptor] { plugins.values.map(\.descriptor).sorted { $0.id < $1.id } }
    public func register(_ plugin: any AppPlugin) throws {
        guard plugins[plugin.descriptor.id] == nil else { throw InstanceError.duplicatePlugin }
        plugins[plugin.descriptor.id] = plugin
    }
    public func validate(appTypeID: String, configuration: Data) throws {
        guard let plugin = plugins[appTypeID] else { throw InstanceError.unknownPlugin }
        try plugin.validate(configuration: configuration)
    }
}

public struct AppInstance: Identifiable, Codable, Equatable {
    public let id: UUID
    public let appTypeID: String
    public let name: String
    public let configuration: Data
    public init(id: UUID = UUID(), appTypeID: String, name: String, configuration: Data) {
        self.id = id; self.appTypeID = appTypeID; self.name = name; self.configuration = configuration
    }
}

public enum InstanceError: Error, LocalizedError {
    case unknownProject, unknownInstance, unknownPlugin, duplicatePlugin, emptyName, duplicateName
    public var errorDescription: String? {
        switch self {
        case .unknownProject: return "Select a project first."
        case .unknownInstance: return "This instance no longer exists."
        case .unknownPlugin: return "This app is not included in this build."
        case .duplicatePlugin: return "An app type was registered twice."
        case .emptyName: return "Enter an instance name."
        case .duplicateName: return "This app already has an instance with this name."
        }
    }
}
