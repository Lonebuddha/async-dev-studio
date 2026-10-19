import AppKit
import Foundation
import StudioKernel
import TerminalPlugin
import CodexPlugin

final class CodexTests {
    func testConfigurationAndValidation() throws {
        let plugin = CodexPlugin()
        try expectEqual(plugin.descriptor.id, "codex")
        try expectFalse(plugin.supportsStartupCommands)
        let data = try plugin.configurationData(shell: "/bin/sh", workingDirectory: "/tmp", startupCommands: ["never run"])
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        try expectNil(object["startupCommands"])
        try expectTrue(try plugin.decodeConfiguration(data).startupCommands.isEmpty)
        try expectThrows(try plugin.validate(configuration: CodexConfiguration(shell: "/missing").encoded()))
        var future = CodexConfiguration(); future.version = 99
        try expectThrows(try plugin.validate(configuration: future.encoded()))
        let registry = PluginRegistry()
        try registry.register(TerminalPlugin()); try registry.register(plugin)
        try expectEqual(registry.descriptors.map(\.id), ["codex", "terminal"])
    }

    @MainActor func testSessionIsolationAndRestart(nativeRuntime: Bool = false) async throws {
        if nativeRuntime { _ = NSApplication.shared }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Codex ' sessions \(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let wrapper = root.appendingPathComponent("fake codex")
        let binary = URL(fileURLWithPath: CommandLine.arguments[0], relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL.path
        try ("#!/bin/sh\nexport STUDIO_FAKE_CODEX_DIR=" + CodexSessionStore.quote(root.path)
            + "\nexec " + CodexSessionStore.quote(binary) + " --fake-codex \"$@\"\n")
            .write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        let store = CodexSessionStore(directory: root.appendingPathComponent("records"))
        let plugin = CodexPlugin(sessions: store, executable: wrapper.path)
        let config = try CodexConfiguration(shell: "/bin/sh", workingDirectory: root.path).encoded()
        let first = AppInstance(appTypeID: "codex", name: "First", configuration: config)
        let second = AppInstance(appTypeID: "codex", name: "Second", configuration: config)
        @MainActor func run(_ instance: AppInstance, using plugin: CodexPlugin) async throws {
            let runtime = TerminalRuntime(plugins: [plugin])
            let session: TerminalSession
            if nativeRuntime {
                try runtime.open(instance)
                session = runtime.controllers[instance.id]!.session
            } else {
                session = TerminalSession(configuration: try plugin.launchConfiguration(for: instance))
            }
            var output = Data()
            session.onOutput = { output.append($0) }
            defer { runtime.close(instance.id); session.stop() }
            try session.start()
            let deadline = Date().addingTimeInterval(10)
            while session.processID != nil {
                if Date() > deadline { throw NSError(domain: "CodexTimeout", code: 1) }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            if session.state != .exited(0) { print(String(decoding: output, as: UTF8.self)) }
            try expectEqual(session.state, .exited(0))
        }
        try await run(first, using: plugin)
        let id = try store.sessionID(for: first.id, workingDirectory: root.path)
        try expectNotNil(id)
        let restarted = CodexPlugin(sessions: CodexSessionStore(directory: store.directory), executable: wrapper.path)
        let resumed = try restarted.launchConfiguration(for: first)
        try expectTrue(resumed.startupCommands[0].contains(" resume '" + id!.uuidString.lowercased() + "'"))
        try expectFalse(resumed.startupCommands[0].contains("--last"))
        try await run(first, using: restarted)
        try expectEqual(try store.sessionID(for: first.id, workingDirectory: root.path), id)
        try await run(second, using: restarted)
        try expectNotEqual(try store.sessionID(for: second.id, workingDirectory: root.path), id)
        let record = try JSONSerialization.jsonObject(with: Data(contentsOf: store.recordURL(for: first.id))) as! [String: Any]
        try expectEqual(Set(record.keys), Set(["session_id", "cwd"]))
        let attrs = try FileManager.default.attributesOfItem(atPath: store.recordURL(for: first.id).path)
        try expectEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let other = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let changed = AppInstance(id: first.id, appTypeID: "codex", name: "Changed",
            configuration: try CodexConfiguration(shell: "/bin/sh", workingDirectory: other.path).encoded())
        try expectFalse(try restarted.launchConfiguration(for: changed).startupCommands[0].contains(" resume "))
        try await run(changed, using: restarted)
        try expectNotEqual(try store.sessionID(for: first.id, workingDirectory: other.path), id)
        try Data("broken".utf8).write(to: store.recordURL(for: first.id))
        try expectThrows(try restarted.launchConfiguration(for: changed))
    }

    func testNotificationRejectsOtherEventsAndMalformedInput() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Codex notify \(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CodexSessionStore(directory: root)
        let instance = UUID()
        let config = try store.notificationConfiguration(for: instance)
        let args = try JSONDecoder().decode([String].self, from: Data(config.dropFirst("notify=".count).utf8))
        func notify(_ payload: String) throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: args[0])
            process.arguments = Array(args.dropFirst()) + [payload]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            return process.terminationStatus
        }
        try expectEqual(try notify("{\"type\":\"other\"}"), 0)
        try expectNil(try store.sessionID(for: instance, workingDirectory: root.path))
        try expectNotEqual(try notify("bad JSON"), 0)
        try expectNotEqual(try notify("{\"type\":\"agent-turn-complete\"}"), 0)
        try expectNil(try store.sessionID(for: instance, workingDirectory: root.path))
    }

    static func fakeCLI(arguments: [String]) throws {
        guard arguments.contains("--no-alt-screen"), arguments.contains("--dangerously-bypass-approvals-and-sandbox"),
              let index = arguments.firstIndex(of: "-c"), index + 1 < arguments.count else {
            throw NSError(domain: "CodexFixtureArguments", code: 1)
        }
        let config = arguments[index + 1]
        guard config.hasPrefix("notify=") else { throw NSError(domain: "CodexFixtureNotify", code: 1) }
        let args = try JSONDecoder().decode([String].self, from: Data(config.dropFirst("notify=".count).utf8))
        let id = arguments.first == "resume" ? arguments[1] : UUID().uuidString.lowercased()
        let payload: [String: Any] = ["type": "agent-turn-complete", "thread-id": id,
            "cwd": FileManager.default.currentDirectoryPath, "last-assistant-message": "Do not store this text"]
        let notification = Process()
        notification.executableURL = URL(fileURLWithPath: args[0])
        notification.arguments = Array(args.dropFirst()) + [String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)]
        try notification.run(); notification.waitUntilExit()
        guard notification.terminationStatus == 0 else { throw NSError(domain: "CodexFixtureCallback", code: 1) }
    }
}
