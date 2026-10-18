import StudioKernel
import StudioPresentation

final class WorkspaceModelTests {
    @MainActor func testCreateSelectsNewProjectAndClosesForm() async throws {
        let model = WorkspaceModel(kernel: try ProjectKernel(store: TestStore()))
        model.beginCreatingProject()
        model.draftName = "Portal"
        model.createProject()
        try expectEqual(model.projects.map(\.name), ["Portal"])
        try expectEqual(model.selectedProjectID, model.projects.first?.id)
        try expectFalse(model.isCreatingProject)
    }

    @MainActor func testCancelCreatesNothingAndClearsDraftOnNextAttempt() async throws {
        let model = WorkspaceModel(kernel: try ProjectKernel(store: TestStore()))
        model.beginCreatingProject()
        model.draftName = "Unfinished"
        model.cancelCreatingProject()
        try expectTrue(model.projects.isEmpty)
        model.beginCreatingProject()
        try expectEqual(model.draftName, "")
        try expectNil(model.creationError)
    }

    @MainActor func testInvalidNameKeepsFormOpenAndShowsError() async throws {
        let model = WorkspaceModel(kernel: try ProjectKernel(store: TestStore()))
        model.beginCreatingProject()
        model.draftName = " \n"
        model.createProject()
        try expectTrue(model.isCreatingProject)
        try expectTrue(model.projects.isEmpty)
        try expectNil(model.selectedProjectID)
        try expectNotNil(model.creationError)
    }

    @MainActor func testFailedSaveKeepsDraftAndAllowsRetry() async throws {
        let store = TestStore()
        let model = WorkspaceModel(kernel: try ProjectKernel(store: store))
        model.beginCreatingProject()
        model.draftName = "Portal"
        store.failSave = true
        model.createProject()
        try expectTrue(model.isCreatingProject)
        try expectEqual(model.draftName, "Portal")
        try expectTrue(model.projects.isEmpty)
        try expectNotNil(model.creationError)
        store.failSave = false
        model.createProject()
        try expectFalse(model.isCreatingProject)
        try expectNil(model.creationError)
        try expectEqual(model.projects.count, 1)
    }
}

private final class TestStore: ProjectStore {
    var projects: [Project] = []
    var failSave = false
    func load() throws -> [Project] { projects }
    func save(_ projects: [Project]) throws {
        if failSave { throw Failure.storage }
        self.projects = projects
    }
    private enum Failure: Error { case storage }
}
