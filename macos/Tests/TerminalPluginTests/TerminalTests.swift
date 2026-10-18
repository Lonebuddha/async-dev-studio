import Foundation
import StudioKernel
import StudioPresentation
import AppKit
import SwiftTerm
@testable import TerminalPlugin

final class TerminalTests {
    @MainActor func testCommandCopyPreservesSelectionAndClipboard() throws {
        _ = NSApplication.shared
        let clipboard = NSPasteboard.general
        let saved = (clipboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        defer {
            clipboard.clearContents()
            let items = saved.map { values in
                let item = NSPasteboardItem()
                values.forEach { item.setData($0.1, forType: $0.0) }
                return item
            }
            clipboard.writeObjects(items)
        }
        let controller = TerminalController(configuration: TerminalConfiguration())
        let window = NSWindow(contentRect: controller.view.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = TerminalHostView(terminalView: controller.view)
        window.makeFirstResponder(controller.view)
        controller.view.feed(byteArray: Array("COPY_MARKER café".utf8)[...])
        controller.view.selectAll(nil)
        try expectTrue(String(decoding: controller.view.terminal.getBufferAsData(), as: UTF8.self).contains("COPY_MARKER café"))
        try expectEqual(controller.view.getSelection()?.trimmingCharacters(in: .whitespacesAndNewlines), "COPY_MARKER café")
        clipboard.clearContents()
        try expectTrue(clipboard.setString("previous", forType: .string))
        try expectEqual(clipboard.string(forType: .string), "previous")
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8)!
        // Consume the shortcut before it falls through to SwiftTerm's keyDown.
        try expectTrue(controller.view.performKeyEquivalent(with: key))
        try expectEqual(clipboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), "COPY_MARKER café")
        controller.view.selectNone()
        clipboard.clearContents()
        clipboard.setString("keep me", forType: .string)
        try expectTrue(controller.view.performKeyEquivalent(with: key))
        try expectEqual(clipboard.string(forType: .string), "keep me")
        controller.view.selectAll(nil)
        let menu = controller.view.menu(for: key)!
        let copy = menu.item(withTitle: "Copy")!
        try expectTrue(NSApplication.shared.sendAction(copy.action!, to: copy.target, from: copy))
        try expectTrue(clipboard.string(forType: .string)?.contains("COPY_MARKER café") == true)
        // Real mouse selection must work in both drag directions as well.
        let left = NSPoint(x: 2, y: controller.view.bounds.height - 5)
        let right = NSPoint(x: 150, y: controller.view.bounds.height - 5)
        for (start, finish) in [(left, right), (right, left)] {
            controller.view.selectNone()
            let mouse = { (type: NSEvent.EventType, point: NSPoint) in
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            controller.view.mouseDown(with: mouse(.leftMouseDown, start))
            controller.view.mouseDragged(with: mouse(.leftMouseDragged, start))
            controller.view.mouseDragged(with: mouse(.leftMouseDragged, finish))
            controller.view.mouseUp(with: mouse(.leftMouseUp, finish))
            try expectTrue(controller.view.performKeyEquivalent(with: key))
            try expectTrue(clipboard.string(forType: .string)?.contains("COPY_MARKER café") == true)
        }
    }
    @MainActor func testStartupKeepsInteractiveShellState() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // Model Conda's shell initialization, including its automatic base activation.
        try "export ACTIVE_ENV=base\nactivate() { export ACTIVE_ENV=\"$1\"; }\nprintf x >> \"$ZDOTDIR/rc-count\"\n".write(to: folder.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        let oldZdotdir = ProcessInfo.processInfo.environment["ZDOTDIR"]
        setenv("ZDOTDIR", folder.path, 1)
        defer {
            if let oldZdotdir { setenv("ZDOTDIR", oldZdotdir, 1) } else { unsetenv("ZDOTDIR") }
        }
        let session = TerminalSession(configuration: TerminalConfiguration(shell: "/bin/zsh", workingDirectory: folder.path,
            startupCommands: ["activate cobra", "studio_local=preserved", "studio_function() { printf function; }", "printf ready > ready"]))
        defer { session.stop() }
        try session.start()
        let pid = session.processID
        try await waitUntil { FileManager.default.fileExists(atPath: folder.appendingPathComponent("ready").path) }
        session.send(Data("printf '%s:%s:' \"$ACTIVE_ENV\" \"$studio_local\" > result; studio_function >> result; printf done > done\n".utf8))
        try await waitUntil { FileManager.default.fileExists(atPath: folder.appendingPathComponent("done").path) }
        try expectEqual(try String(contentsOf: folder.appendingPathComponent("result")), "cobra:preserved:function")
        try expectEqual(try String(contentsOf: folder.appendingPathComponent("rc-count")), "x")
        try expectEqual(session.processID, pid)
    }
    @MainActor func testTabReattachmentPreservesScreenAndProcess() async throws {
        _ = NSApplication.shared
        let controller = TerminalController(configuration: TerminalConfiguration(shell: "/bin/sh"))
        controller.start()
        defer { controller.session.stop() }
        let pid = controller.session.processID
        try expectNotNil(pid)
        let host = TerminalHostView(terminalView: controller.view)
        host.frame.size = NSSize(width: 800, height: 480)
        host.layout()
        // Alternate-screen applications have no scrollback to recover discarded lines.
        controller.view.feed(byteArray: Array("\u{1b}[?1049h\u{1b}[2J\u{1b}[HTAB_MARKER\r\nSECOND_LINE".utf8)[...])
        let before = controller.view.terminal.getBufferAsData()
        let columns = controller.view.terminal.cols
        let rows = controller.view.terminal.rows
        host.frame.size = .zero
        host.layout()
        try expectEqual(controller.view.terminal.cols, columns)
        try expectEqual(controller.view.terminal.rows, rows)
        let replacement = TerminalHostView(terminalView: controller.view)
        replacement.frame.size = NSSize(width: 1, height: 1)
        replacement.layout()
        replacement.frame.size = NSSize(width: 800, height: 480)
        replacement.layout()
        try expectEqual(controller.view.terminal.getBufferAsData(), before)
        try expectEqual(controller.session.processID, pid)
        replacement.frame.size = NSSize(width: 1000, height: 600)
        replacement.layout()
        try expectTrue(controller.view.terminal.cols > columns)
        try expectTrue(controller.view.terminal.rows > rows)
        try expectEqual(controller.session.processID, pid)
    }
    func testRegistryRejectsDuplicateTypes() throws {
        let registry = PluginRegistry()
        try registry.register(TerminalPlugin())
        try expectThrows(try registry.register(TerminalPlugin()))
        try expectEqual(registry.descriptors.map(\.id), ["terminal"])
    }

    func testKernelStoresIndependentInstances() throws {
        let store = TerminalTestStore()
        let registry = PluginRegistry()
        try registry.register(TerminalPlugin())
        let kernel = try ProjectKernel(store: store, plugins: registry)
        let first = try kernel.createProject(name: "First")
        let second = try kernel.createProject(name: "Second")
        let config = try TerminalConfiguration().encoded()
        let a = try kernel.createInstance(projectID: first.id, appTypeID: "terminal", name: "Shell", configuration: config)
        let b = try kernel.createInstance(projectID: second.id, appTypeID: "terminal", name: "Shell", configuration: config)
        try expectNotEqual(a.id, b.id)
        try expectEqual(kernel.projects[0].instances, [a])
        try expectEqual(kernel.projects[1].instances, [b])
        try expectEqual(store.projects, kernel.projects)
    }

    func testInvalidConfigurationAndUnknownPluginAreNotSaved() throws {
        let store = TerminalTestStore()
        let registry = PluginRegistry()
        try registry.register(TerminalPlugin())
        let kernel = try ProjectKernel(store: store, plugins: registry)
        let project = try kernel.createProject(name: "Project")
        let invalid = try TerminalConfiguration(shell: "/not/a/shell").encoded()
        try expectThrows(try kernel.createInstance(projectID: project.id, appTypeID: "terminal", name: "Shell", configuration: invalid))
        try expectThrows(try kernel.createInstance(projectID: project.id, appTypeID: "missing", name: "Shell", configuration: Data()))
        try expectTrue(kernel.projects[0].instances.isEmpty)
        try expectEqual(store.projects, kernel.projects)
    }

    func testInstanceSaveFailureDoesNotPublish() throws {
        let store = TerminalTestStore()
        let registry = PluginRegistry()
        try registry.register(TerminalPlugin())
        let kernel = try ProjectKernel(store: store, plugins: registry)
        let project = try kernel.createProject(name: "Project")
        store.failSave = true
        try expectThrows(try kernel.createInstance(projectID: project.id, appTypeID: "terminal", name: "Shell", configuration: try TerminalConfiguration().encoded()))
        try expectTrue(kernel.projects[0].instances.isEmpty)
    }

    func testOldProjectDocumentStillLoads() throws {
        let id = UUID()
        let data = Data("{\"id\":\"\(id)\",\"name\":\"Existing\"}".utf8)
        let project = try JSONDecoder().decode(Project.self, from: data)
        try expectEqual(project.id, id)
        try expectTrue(project.instances.isEmpty)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("projects.json")
        let legacy = Data("{\"version\":1,\"projects\":[\(String(decoding: data, as: UTF8.self))]}".utf8)
        try legacy.write(to: file)
        let restored = try ProjectKernel(store: JSONProjectStore(fileURL: file))
        try expectEqual(restored.projects, [project])
    }

    func testInstancesSurviveRestart() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = JSONProjectStore(fileURL: folder.appendingPathComponent("projects.json"))
        let registry = PluginRegistry()
        try registry.register(TerminalPlugin())
        let kernel = try ProjectKernel(store: store, plugins: registry)
        let project = try kernel.createProject(name: "Project")
        let configuration = TerminalConfiguration(startupCommands: ["printf hello"])
        let instance = try kernel.createInstance(projectID: project.id, appTypeID: "terminal", name: "Development", configuration: try configuration.encoded())
        let restored = try ProjectKernel(store: store, plugins: registry)
        try expectEqual(restored.projects[0].instances, [instance])
        try expectEqual(try TerminalConfiguration.decode(restored.projects[0].instances[0].configuration), configuration)
    }

    @MainActor func testOpeningReusesTabAndProjectsKeepSeparateTabs() async throws {
        let registry = PluginRegistry()
        try registry.register(TerminalPlugin())
        let kernel = try ProjectKernel(store: TerminalTestStore(), plugins: registry)
        let first = try kernel.createProject(name: "First")
        let second = try kernel.createProject(name: "Second")
        let a = try kernel.createInstance(projectID: first.id, appTypeID: "terminal", name: "Shell", configuration: try TerminalConfiguration().encoded())
        let b = try kernel.createInstance(projectID: second.id, appTypeID: "terminal", name: "Shell", configuration: try TerminalConfiguration().encoded())
        let model = WorkspaceModel(kernel: kernel)
        model.openInstance(a.id)
        model.openInstance(a.id)
        try expectEqual(model.openInstances.map(\.id), [a.id])
        model.openInstance(b.id)
        try expectEqual(model.selectedProjectID, second.id)
        try expectEqual(model.openInstances.map(\.id), [b.id])
        model.selectedProjectID = first.id
        try expectEqual(model.openInstances.map(\.id), [a.id])
        try expectEqual(model.selectedInstanceID, a.id)
        model.closeInstance(a.id)
        try expectTrue(model.openInstances.isEmpty)
        try expectEqual(model.projects[0].instances, [a])
    }

    @MainActor func testInteractivePTYAndResize() async throws {
        let session = TerminalSession(configuration: TerminalConfiguration(shell: "/bin/sh"))
        var output = ""
        session.onOutput = { output += String(decoding: $0, as: UTF8.self) }
        defer { session.stop() }
        try session.start()
        try session.resize(columns: 101, rows: 37)
        session.send(Data("test -t 0 && printf '__PTY_OK__\\n'; stty size; printf '__SIZE_DONE__\\n'\n".utf8))
        try await waitUntil { output.contains("37 101") && output.contains("__PTY_OK__\r\n") }
        try expectEqual(session.state, .running)
    }

    @MainActor func testStartupRunsOnceAndUsesWorkingDirectory() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("terminal test '\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let config = TerminalConfiguration(shell: "/bin/sh", workingDirectory: folder.path,
            startupCommands: ["printf x >> started.txt"])
        let session = TerminalSession(configuration: config)
        defer { session.stop() }
        try session.start()
        try session.start()
        let marker = folder.appendingPathComponent("started.txt")
        try await waitUntil { FileManager.default.fileExists(atPath: marker.path) }
        try expectEqual(try String(contentsOf: marker), "x")
        session.send(Data("exit\n".utf8))
        try await waitUntil { session.state != .running }
    }

    @MainActor func testStartupFailureEndsSession() async throws {
        let session = TerminalSession(configuration: TerminalConfiguration(shell: "/bin/sh", startupCommands: ["false", "touch SHOULD_NOT_EXIST"]))
        try session.start()
        defer { session.stop() }
        try await waitUntil { session.state != .running }
        try expectEqual(session.state, .exited(1))
    }

    @MainActor func testStopCleansUpShellAndForegroundProcess() async throws {
        let session = TerminalSession(configuration: TerminalConfiguration(shell: "/bin/sh"))
        try session.start()
        let pid = session.processID
        var output = ""
        session.onOutput = { output += String(decoding: $0, as: UTF8.self) }
        session.send(Data("sh -c 'echo __CHILD_$$__; exec sleep 30'\n".utf8))
        let regex = try NSRegularExpression(pattern: "__CHILD_([0-9]+)__")
        try await waitUntil { regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)) != nil }
        let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output))!
        let childPID = Int32((output as NSString).substring(with: match.range(at: 1)))!
        session.stop()
        try await waitUntil { session.processID == nil && kill(childPID, 0) == -1 }
        try expectEqual(session.state, .stopped)
        if let pid { try expectEqual(kill(pid, 0), -1) }
    }

    func testConfigureRenameAndDeletePersistWithoutChangingIdentity() throws {
        let store = TerminalTestStore()
        let registry = PluginRegistry()
        try registry.register(TerminalPlugin())
        let kernel = try ProjectKernel(store: store, plugins: registry)
        let project = try kernel.createProject(name: "Project")
        let instance = try kernel.createInstance(projectID: project.id, appTypeID: "terminal", name: "Shell", configuration: try TerminalConfiguration().encoded())
        let config = try TerminalConfiguration(startupCommands: ["printf changed"]).encoded()
        try kernel.updateInstance(id: instance.id, name: "Renamed", configuration: config)
        try expectEqual(kernel.projects[0].instances[0].id, instance.id)
        try expectEqual(kernel.projects[0].instances[0].name, "Renamed")
        try expectEqual(kernel.projects[0].instances[0].configuration, config)
        store.failSave = true
        try expectThrows(try kernel.deleteInstance(id: instance.id))
        try expectEqual(kernel.projects[0].instances.count, 1)
        store.failSave = false
        try kernel.deleteInstance(id: instance.id)
        try expectTrue(kernel.projects[0].instances.isEmpty)
        try expectEqual(store.projects, kernel.projects)
    }

    @MainActor func testConfigurationChangesWaitForNextStart() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = TerminalSession(configuration: TerminalConfiguration(shell: "/bin/sh", workingDirectory: folder.path))
        defer { session.stop() }
        try session.start()
        let pid = session.processID
        try session.configureForNextStart(TerminalConfiguration(shell: "/bin/sh", workingDirectory: folder.path, startupCommands: ["printf updated > marker"]))
        let marker = folder.appendingPathComponent("marker")
        try expectFalse(FileManager.default.fileExists(atPath: marker.path))
        try expectEqual(session.processID, pid)
        session.send(Data("exit\n".utf8))
        try await waitUntil { session.processID == nil }
        try session.start()
        try await waitUntil { FileManager.default.fileExists(atPath: marker.path) }
        try expectEqual(try String(contentsOf: marker), "updated")
    }

    @MainActor func testExecFailureHasNoLiveProcess() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("not an executable image".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        defer { try? FileManager.default.removeItem(at: file) }
        let session = TerminalSession(configuration: TerminalConfiguration(shell: file.path))
        try expectThrows(try session.start())
        try expectNil(session.processID)
        session.stop()
        if case .failed = session.state {} else { try expectTrue(false) }
    }

}

private final class TerminalTestStore: ProjectStore {
    var projects: [Project] = []
    var failSave = false
    func load() throws -> [Project] { projects }
    func save(_ projects: [Project]) throws {
        if failSave { throw Failure.storage }
        self.projects = projects
    }
    enum Failure: Error { case storage }
}

@MainActor
private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { throw TerminalTestTimeout() }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
}
private struct TerminalTestTimeout: Error {}
