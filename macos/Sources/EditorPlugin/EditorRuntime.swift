import AppKit
import Combine
import StudioKernel

@MainActor
public final class EditorRuntime: ObservableObject {
    @Published public private(set) var controllers: [UUID: EditorWorkspace] = [:]
    public init() {}
    public func open(_ instance: AppInstance) throws {
        guard instance.appTypeID == "editor", controllers[instance.id] == nil else { return }
        let configuration = try EditorConfiguration.decode(instance.configuration)
        try configuration.validate()
        controllers[instance.id] = try EditorWorkspace(folder: URL(fileURLWithPath: configuration.folder))
    }
    public func approveClose(_ id: UUID) throws -> Bool {
        try controllers[id]?.prepareToClose(decision: Self.askToSave) ?? true
    }
    public func approveQuit() throws -> Bool {
        for controller in controllers.values {
            guard try controller.prepareToClose(decision: Self.askToSave) else { return false }
        }
        return true
    }
    public func closeApproved(_ id: UUID) { controllers[id] = nil }
    public static func askToSave(_ document: EditorDocument) -> EditorCloseDecision {
        let alert = NSAlert()
        alert.messageText = "Save changes to \(document.url.lastPathComponent)?"
        alert.informativeText = document.url.path
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Don’t Save"); alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertSecondButtonReturn: return .discard
        default: return .cancel
        }
    }
}
