import Foundation
import StudioKernel

final class ProjectKernelTests {
    func testFirstWorkspaceIsEmpty() throws {
        let kernel = try ProjectKernel(store: MemoryProjectStore())
        try expectTrue(kernel.projects.isEmpty)
    }

    func testCreatesProjectWithNameAndSavesIt() throws {
        let store = MemoryProjectStore()
        let kernel = try ProjectKernel(store: store)
        let project = try kernel.createProject(name: "Customer Portal")
        try expectEqual(project.name, "Customer Portal")
        try expectEqual(kernel.projects, [project])
        try expectEqual(store.projects, [project])
    }

    func testTrimsSurroundingWhitespace() throws {
        let kernel = try ProjectKernel(store: MemoryProjectStore())
        try expectEqual(try kernel.createProject(name: "  Portal\n").name, "Portal")
    }

    func testRejectsEmptyNamesWithoutSaving() throws {
        let store = MemoryProjectStore()
        let kernel = try ProjectKernel(store: store)
        for name in ["", " \n\t"] {
            try expectThrows(try kernel.createProject(name: name)) {
                try expectEqual($0 as? ProjectCreationError, .emptyName)
            }
        }
        try expectTrue(kernel.projects.isEmpty)
        try expectEqual(store.saveCount, 0)
    }

    func testRejectsDuplicateNamesWithoutChangingProjects() throws {
        let store = MemoryProjectStore()
        let kernel = try ProjectKernel(store: store)
        let first = try kernel.createProject(name: "Portal")
        try expectThrows(try kernel.createProject(name: " portal ")) {
            try expectEqual($0 as? ProjectCreationError, .duplicateName)
        }
        try expectEqual(kernel.projects, [first])
        try expectEqual(store.saveCount, 1)
    }

    func testMultipleProjectsHaveIndependentIdentities() throws {
        let kernel = try ProjectKernel(store: MemoryProjectStore())
        let first = try kernel.createProject(name: "Portal")
        let second = try kernel.createProject(name: "Inventory")
        try expectNotEqual(first.id, second.id)
        try expectEqual(kernel.projects, [first, second])
    }

    func testSaveFailurePreservesExistingWorkspace() throws {
        let existing = Project(name: "Existing")
        let store = MemoryProjectStore(projects: [existing])
        store.failSave = true
        let kernel = try ProjectKernel(store: store)
        try expectThrows(try kernel.createProject(name: "New"))
        try expectEqual(kernel.projects, [existing])
        try expectEqual(store.projects, [existing])
    }

    func testLoadFailureIsReported() throws {
        try expectThrows(try ProjectKernel(store: UnreadableStore()))
    }
}

final class MemoryProjectStore: ProjectStore {
    var projects: [Project]
    var saveCount = 0
    var failSave = false

    init(projects: [Project] = []) { self.projects = projects }
    func load() throws -> [Project] { projects }
    func save(_ projects: [Project]) throws {
        if failSave { throw TestFailure.storage }
        saveCount += 1
        self.projects = projects
    }
}

private enum TestFailure: Error { case storage }
private struct UnreadableStore: ProjectStore {
    func load() throws -> [Project] { throw TestFailure.storage }
    func save(_ projects: [Project]) throws {}
}
