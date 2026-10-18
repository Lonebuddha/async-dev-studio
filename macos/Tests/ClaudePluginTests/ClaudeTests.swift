import Foundation
import AppKit
import StudioKernel
import TerminalPlugin
import ClaudePlugin

final class ClaudeTests {
    @MainActor func testSharedRuntimeRestartsAndConfigurationChanges() async throws {
        _ = NSApplication.shared
        try await fixture { root in
            let executable = root.appendingPathComponent("fake claude")
            let binary = URL(fileURLWithPath: CommandLine.arguments[0], relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL.path
            let script = "#!/bin/sh\nexport STUDIO_FAKE_CLAUDE_DIR=" + ClaudeSessionStore.quote(root.path)
                + "\nexec " + ClaudeSessionStore.quote(binary) + " --fake-claude \"$@\"\n"
            try script.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            let sessions = ClaudeSessionStore(directory: root.appendingPathComponent("sessions"))
            let plugin = ClaudePlugin(sessions: sessions, executable: executable.path)
            let runtime = TerminalRuntime(plugins: [TerminalPlugin(), plugin])
            let instance = AppInstance(appTypeID: "claude", name: "Claude",
                configuration: try ClaudeConfiguration(shell: "/bin/sh", workingDirectory: root.path).encoded())
            defer { runtime.stopAll() }
            try runtime.open(instance)
            let controller = runtime.controllers[instance.id]!
            @MainActor func waitForExit() async throws {
                let deadline = Date().addingTimeInterval(10)
                while controller.session.processID != nil {
                    if Date() > deadline { throw NSError(domain: "ClaudeTestTimeout", code: 1) }
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
                try expectEqual(controller.session.state, .exited(0))
            }
            try await waitForExit()
            let firstID = try sessions.sessionID(for: instance.id, workingDirectory: root.path)
            controller.start()
            try await waitForExit()
            try expectEqual(try sessions.sessionID(for: instance.id, workingDirectory: root.path), firstID)
            let other = root.appendingPathComponent("other")
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            try runtime.configure(AppInstance(id: instance.id, appTypeID: "claude", name: "Renamed",
                configuration: ClaudeConfiguration(shell: "/bin/sh", workingDirectory: other.path).encoded()))
            controller.start()
            try await waitForExit()
            try expectNotEqual(try sessions.sessionID(for: instance.id, workingDirectory: other.path), firstID)
            try Data("corrupt".utf8).write(to: sessions.recordURL(for: instance.id))
            controller.start()
            try expectNotNil(controller.startupError)
            try expectNil(controller.session.processID)
            runtime.close(instance.id)
            try expectNil(runtime.controllers[instance.id])
        }
    }
    private func fixture(_ body: (URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Claude session '\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(root)
    }

    func testConfigurationAndSharedBase() throws {
        let claude = ClaudePlugin()
        let normal = TerminalPlugin()
        let plugins: [TerminalAppPlugin] = [normal, claude]
        try expectEqual(plugins.map(\.descriptor.id), ["terminal", "claude"])
        try expectTrue(normal.supportsStartupCommands)
        try expectFalse(claude.supportsStartupCommands)
        let data = try claude.configurationData(shell: "/bin/sh", workingDirectory: "/tmp", startupCommands: ["must not execute"])
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        try expectNil(object["startupCommands"])
        try expectTrue(try claude.decodeConfiguration(data).startupCommands.isEmpty)
        try expectThrows(try claude.validate(configuration: ClaudeConfiguration(shell: "/missing").encoded()))
        let registry = PluginRegistry()
        for plugin in plugins { try registry.register(plugin) }
        try expectEqual(registry.descriptors.map(\.id), ["claude", "terminal"])
    }

    @MainActor func testNewSessionAndResumeAcrossStoreAndProcessRestart() async throws {
        try await fixture { root in
            let wrapper = root.appendingPathComponent("fake claude")
            let binary = CommandLine.arguments[0].hasPrefix("/") ? CommandLine.arguments[0]
                : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(CommandLine.arguments[0]).path
            let script = "#!/bin/sh\nexport STUDIO_FAKE_CLAUDE_DIR=" + ClaudeSessionStore.quote(root.path)
                + "\nexec " + ClaudeSessionStore.quote(binary) + " --fake-claude \"$@\"\n"
            try script.write(to: wrapper, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
            let store = ClaudeSessionStore(directory: root.appendingPathComponent("sessions"))
            let config = try ClaudeConfiguration(shell: "/bin/sh", workingDirectory: root.path).encoded()
            let first = AppInstance(appTypeID: "claude", name: "Claude", configuration: config)
            let second = AppInstance(appTypeID: "claude", name: "Other", configuration: config)
            let plugin = ClaudePlugin(sessions: store, executable: wrapper.path)
            try await run(plugin.launchConfiguration(for: first))
            let id = try store.sessionID(for: first.id, workingDirectory: root.path)
            try expectNotNil(id)
            let restarted = ClaudePlugin(sessions: ClaudeSessionStore(directory: store.directory), executable: wrapper.path)
            try await run(restarted.launchConfiguration(for: first))
            try expectEqual(try store.sessionID(for: first.id, workingDirectory: root.path), id)
            try await run(restarted.launchConfiguration(for: second))
            try expectNotEqual(try store.sessionID(for: second.id, workingDirectory: root.path), id)
            let launches = try JSONDecoder().decode([[String]].self, from: Data(contentsOf: root.appendingPathComponent("launches.json")))
            try expectFalse(launches[0].contains("--resume"))
            try expectTrue(launches[1].contains(id!.uuidString.lowercased()))
            try expectFalse(launches[2].contains("--resume"))
            for args in launches {
                let mode = args.firstIndex(of: "--permission-mode")!
                try expectEqual(args[mode + 1], "bypassPermissions")
            }
            let mode = try FileManager.default.attributesOfItem(atPath: store.recordURL(for: first.id).path)[.posixPermissions] as? NSNumber
            try expectEqual(mode?.intValue, 0o600)
            // Switching working folders must not accidentally resume another folder's session.
            try expectNil(try store.sessionID(for: first.id, workingDirectory: "/tmp"))
        }
    }

    func testEmptyAndCorruptSessionRecords() async throws {
        try await fixture { root in
            let store = ClaudeSessionStore(directory: root)
            let id = UUID()
            try expectNil(try store.sessionID(for: id, workingDirectory: root.path))
            _ = try store.hookSettings(for: id)
            let record = ["session_id": UUID().uuidString, "transcript_path": root.appendingPathComponent("absent.jsonl").path, "cwd": root.path]
            try JSONSerialization.data(withJSONObject: record).write(to: store.recordURL(for: id))
            try expectNil(try store.sessionID(for: id, workingDirectory: root.path))
            try Data("not json".utf8).write(to: store.recordURL(for: id))
            try expectThrows(try store.sessionID(for: id, workingDirectory: root.path))
        }
    }

    func testClaudeDefinitionsPersist() async throws {
        try await fixture { root in
            let registry = PluginRegistry()
            try registry.register(ClaudePlugin())
            let store = JSONProjectStore(fileURL: root.appendingPathComponent("projects.json"))
            let kernel = try ProjectKernel(store: store, plugins: registry)
            let project = try kernel.createProject(name: "Project")
            let instance = try kernel.createInstance(projectID: project.id, appTypeID: "claude", name: "Claude",
                configuration: ClaudeConfiguration(workingDirectory: root.path).encoded())
            try expectEqual(try ProjectKernel(store: store, plugins: registry).projects[0].instances, [instance])
        }
    }

    @MainActor private func run(_ configuration: TerminalConfiguration) async throws {
        let session = TerminalSession(configuration: configuration)
        defer { session.stop() }
        try session.start()
        let deadline = Date().addingTimeInterval(10)
        while session.processID != nil {
            if Date() > deadline { throw NSError(domain: "ClaudeTestTimeout", code: 1) }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try expectEqual(session.state, .exited(0))
    }

    /// Controlled local CLI fixture: invokes the real generated hook and writes a fake transcript.
    static func fakeCLI(arguments: [String]) throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["STUDIO_FAKE_CLAUDE_DIR"]!)
        let log = root.appendingPathComponent("launches.json")
        var launches = (try? JSONDecoder().decode([[String]].self, from: Data(contentsOf: log))) ?? []
        launches.append(arguments)
        try JSONEncoder().encode(launches).write(to: log, options: .atomic)
        let id = arguments.firstIndex(of: "--resume").map { arguments[$0 + 1] } ?? UUID().uuidString.lowercased()
        let transcript = root.appendingPathComponent("\(id).jsonl")
        try Data("{\"type\":\"user\",\"message\":\"fixture\"}\n".utf8).write(to: transcript)
        let settingsIndex = arguments.firstIndex(of: "--settings")!
        let settings = try JSONSerialization.jsonObject(with: Data(arguments[settingsIndex + 1].utf8)) as! [String: Any]
        let events = settings["hooks"] as! [String: Any]
        let start = (events["SessionStart"] as! [[String: Any]])[0]
        let hook = (start["hooks"] as! [[String: Any]])[0]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", hook["command"] as! String]
        let pipe = Pipe()
        process.standardInput = pipe
        try process.run()
        let payload = ["session_id": id, "transcript_path": transcript.path, "cwd": FileManager.default.currentDirectoryPath]
        try pipe.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: payload))
        try pipe.fileHandleForWriting.close()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NSError(domain: "ClaudeHookFailed", code: Int(process.terminationStatus)) }
    }
}
