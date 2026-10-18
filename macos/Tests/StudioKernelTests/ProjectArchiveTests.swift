import Foundation
import StudioKernel
import StudioPresentation

final class ProjectArchiveTests {
    func testArchiveRestoreAndRenamePersist() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONProjectStore(fileURL: root.appendingPathComponent("projects.json"))
        let instance = AppInstance(appTypeID: "terminal", name: "Shell", configuration: Data([1, 2]))
        let project = Project(name: "Project", instances: [instance])
        try store.save([project])
        let kernel = try ProjectKernel(store: store)
        try kernel.setProjectArchived(id: project.id, archived: true)
        try kernel.renameProject(id: project.id, name: "Renamed")
        let reloaded = try ProjectKernel(store: store)
        try expectTrue(reloaded.projects[0].isArchived)
        try expectEqual(reloaded.projects[0].instances, [instance])
        try expectEqual(reloaded.projects[0].id, project.id)
        try reloaded.setProjectArchived(id: project.id, archived: false)
        try expectFalse(try ProjectKernel(store: store).projects[0].isArchived)
    }

    func testLegacyProjectDefaultsToUnarchived() throws {
        let data = Data("{\"id\":\"\(UUID())\",\"name\":\"Old project\"}".utf8)
        try expectFalse(try JSONDecoder().decode(Project.self, from: data).isArchived)
    }

    @MainActor func testArchiveFailureKeepsSelectionAndTabs() throws {
        let instance = AppInstance(appTypeID: "terminal", name: "Shell", configuration: Data())
        let project = Project(name: "Project", instances: [instance])
        let store = MemoryProjectStore(projects: [project])
        let kernel = try ProjectKernel(store: store)
        let model = WorkspaceModel(kernel: kernel)
        model.openInstance(instance.id)
        store.failSave = true
        try expectThrows(try model.setProjectArchived(id: project.id, archived: true))
        try expectEqual(kernel.projects, [project])
        try expectEqual(model.visibleProjects, [project])
        try expectEqual(model.selectedProjectID, project.id)
        try expectEqual(model.openInstances, [instance])
        try expectThrows(try kernel.setProjectArchived(id: UUID(), archived: true))
    }

    @MainActor func testArchiveVisibilityAndRetainedTabs() throws {
        let instance = AppInstance(appTypeID: "terminal", name: "Shell", configuration: Data())
        let first = Project(name: "First", instances: [instance]), second = Project(name: "Second")
        let model = WorkspaceModel(kernel: try ProjectKernel(store: MemoryProjectStore(projects: [first, second])))
        model.openInstance(instance.id)
        try model.setProjectArchived(id: first.id, archived: true)
        try expectEqual(model.visibleProjects, [second])
        try expectEqual(model.selectedProjectID, second.id)
        model.showArchivedProjects = true
        try expectEqual(model.visibleProjects.map(\.id), [first.id, second.id])
        model.selectedProjectID = first.id
        try expectEqual(model.openInstances, [instance])
        try expectEqual(model.selectedInstanceID, instance.id)
        model.showArchivedProjects = false
        try expectEqual(model.selectedProjectID, second.id)
        model.openInstance(instance.id)
        try expectEqual(model.selectedProjectID, second.id)
        model.showArchivedProjects = true
        model.openInstance(instance.id)
        try model.setProjectArchived(id: first.id, archived: false)
        model.showArchivedProjects = false
        try expectEqual(model.selectedProjectID, first.id)
        try expectEqual(model.visibleProjects.map(\.id), [first.id, second.id])
        try expectEqual(model.openInstances, [instance])
    }

    @MainActor func testAllArchivedAndDeletionSelection() throws {
        let first = Project(name: "First"), second = Project(name: "Second")
        let model = WorkspaceModel(kernel: try ProjectKernel(store: MemoryProjectStore(projects: [first, second])))
        model.selectedProjectID = first.id
        try model.setProjectArchived(id: first.id, archived: true)
        try model.deleteProject(id: second.id)
        try expectNil(model.selectedProjectID)
        try expectTrue(model.visibleProjects.isEmpty)
        try expectEqual(model.projects.count, 1)
        model.showArchivedProjects = true
        model.selectedProjectID = first.id
        model.showArchivedProjects = false
        try expectNil(model.selectedProjectID)
        try model.setProjectArchived(id: first.id, archived: false)
        try expectEqual(model.visibleProjects.map(\.id), [first.id])
    }
}
