import Foundation
import StudioKernel

final class JSONProjectStoreTests {
    private var directory: URL!

    func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testMissingFileMeansEmptyWorkspace() throws {
        let store = JSONProjectStore(fileURL: directory.appendingPathComponent("projects.json"))
        try expectEqual(try store.load(), [])
    }

    func testProjectsSurviveNewKernelAndStore() throws {
        let fileURL = directory.appendingPathComponent("nested/projects.json")
        let first = try ProjectKernel(store: JSONProjectStore(fileURL: fileURL))
        let project = try first.createProject(name: "Customer Portal")
        let second = try ProjectKernel(store: JSONProjectStore(fileURL: fileURL))
        try expectEqual(second.projects, [project])
    }

    func testCorruptFileIsReportedAndNotOverwritten() throws {
        let fileURL = directory.appendingPathComponent("projects.json")
        let content = Data("not JSON".utf8)
        try content.write(to: fileURL)
        try expectThrows(try ProjectKernel(store: JSONProjectStore(fileURL: fileURL)))
        try expectEqual(try Data(contentsOf: fileURL), content)
    }

    func testUnsupportedStorageVersionIsRejected() throws {
        let fileURL = directory.appendingPathComponent("projects.json")
        try Data(#"{"version":999,"projects":[]}"#.utf8).write(to: fileURL)
        try expectThrows(try JSONProjectStore(fileURL: fileURL).load())
    }
}
