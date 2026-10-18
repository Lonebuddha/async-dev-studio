import Foundation
import StudioKernel
import StudioPresentation

final class ProjectManagementTests {
    func testRenamePreservesIdentityInstancesAndPersists() throws {
        let instance = AppInstance(appTypeID: "editor", name: "Code", configuration: Data([1]))
        let project = Project(name: "Old", instances: [instance])
        let store = MemoryProjectStore(projects: [project])
        let kernel = try ProjectKernel(store: store)
        let renamed = try kernel.renameProject(id: project.id, name: "  New Name\n")
        try expectEqual(renamed.id, project.id)
        try expectEqual(renamed.instances, [instance])
        try expectEqual(renamed.name, "New Name")
        try expectEqual(try ProjectKernel(store: store).projects, [renamed])
    }
    func testRenameValidatesNamesAndAllowsSameProjectName() throws {
        let first = Project(name: "Portal"), second = Project(name: "Inventory")
        let store = MemoryProjectStore(projects: [first, second])
        let kernel = try ProjectKernel(store: store)
        try expectThrows(try kernel.renameProject(id: first.id, name: " \n"))
        try expectThrows(try kernel.renameProject(id: first.id, name: " inventory "))
        try expectThrows(try kernel.renameProject(id: UUID(), name: "New"))
        try expectEqual(store.saveCount, 0)
        let renamed = try kernel.renameProject(id: first.id, name: "PORTAL")
        try expectEqual(renamed.name, "PORTAL")
    }
    func testFailedRenameAndDeletePreserveWorkspace() throws {
        let project = Project(name: "Portal", instances: [AppInstance(appTypeID: "terminal", name: "Shell", configuration: Data())])
        let store = MemoryProjectStore(projects: [project]); store.failSave = true
        let kernel = try ProjectKernel(store: store)
        try expectThrows(try kernel.renameProject(id: project.id, name: "Renamed"))
        try expectThrows(try kernel.deleteProject(id: project.id))
        try expectEqual(kernel.projects, [project]); try expectEqual(store.projects, [project])
    }
    func testDeletePersistsAndDoesNotTouchSourceFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.txt")
        try Data("source".utf8).write(to: source)
        let store = JSONProjectStore(fileURL: root.appendingPathComponent("workspace.json"))
        let project = Project(name: "Delete", instances: [AppInstance(appTypeID: "editor", name: "Code", configuration: Data(root.path.utf8))])
        let other = Project(name: "Keep")
        try store.save([project, other])
        let kernel = try ProjectKernel(store: store)
        try kernel.deleteProject(id: project.id)
        try expectEqual(try ProjectKernel(store: store).projects, [other])
        try expectEqual(try String(contentsOf: source), "source")
        try expectThrows(try kernel.deleteProject(id: project.id))
    }
    @MainActor func testRenameKeepsActiveProjectAndTabs() throws {
        let instance = AppInstance(appTypeID: "browser", name: "JIRA", configuration: Data())
        let project = Project(name: "Old", instances: [instance])
        let model = WorkspaceModel(kernel: try ProjectKernel(store: MemoryProjectStore(projects: [project])))
        model.openInstance(instance.id)
        try model.renameProject(id: project.id, name: "New")
        try expectEqual(model.selectedProject?.name, "New")
        try expectEqual(model.selectedProjectID, project.id)
        try expectEqual(model.openInstances, [instance])
        try expectEqual(model.selectedInstanceID, instance.id)
    }
    @MainActor func testDeleteSwitchesSelectionAndClearsOnlyDeletedTabs() throws {
        let firstInstance = AppInstance(appTypeID: "editor", name: "Code", configuration: Data())
        let secondInstance = AppInstance(appTypeID: "terminal", name: "Shell", configuration: Data())
        let first = Project(name: "First", instances: [firstInstance]), second = Project(name: "Second", instances: [secondInstance])
        let model = WorkspaceModel(kernel: try ProjectKernel(store: MemoryProjectStore(projects: [first, second])))
        model.openInstance(secondInstance.id); model.openInstance(firstInstance.id)
        try model.deleteProject(id: first.id)
        try expectEqual(model.selectedProjectID, second.id)
        try expectEqual(model.openInstances, [secondInstance])
        try expectEqual(model.selectedInstanceID, secondInstance.id)
        try model.deleteProject(id: second.id)
        try expectNil(model.selectedProjectID); try expectNil(model.selectedInstanceID)
        try expectTrue(model.openInstances.isEmpty); try expectTrue(model.projects.isEmpty)
    }
    @MainActor func testFailedDeletePreservesSelectionAndOpenTabs() throws {
        let instance = AppInstance(appTypeID: "terminal", name: "Shell", configuration: Data())
        let project = Project(name: "Project", instances: [instance])
        let store = MemoryProjectStore(projects: [project])
        let model = WorkspaceModel(kernel: try ProjectKernel(store: store)); model.openInstance(instance.id)
        store.failSave = true
        try expectThrows(try model.deleteProject(id: project.id))
        try expectEqual(model.selectedProjectID, project.id)
        try expectEqual(model.openInstances, [instance])
        try expectEqual(model.selectedInstanceID, instance.id)
    }
    @MainActor func testDeletingInactiveProjectKeepsCurrentSelection() throws {
        let first = Project(name: "First"), second = Project(name: "Second")
        let model = WorkspaceModel(kernel: try ProjectKernel(store: MemoryProjectStore(projects: [first, second])))
        model.selectedProjectID = second.id
        try model.deleteProject(id: first.id)
        try expectEqual(model.selectedProjectID, second.id)
    }
}
