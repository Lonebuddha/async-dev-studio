import Darwin
import Foundation
import StudioPlatform

final class ApplicationUpdateTests {
    private var script: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/install-update.sh")
    }
    private func fixture(_ body: (URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Update ' $() \(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(root)
    }
    private func publish(_ version: String, root: URL) throws -> PendingApplicationUpdate {
        let package = root.appendingPathComponent("packages/\(version).app", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let update = PendingApplicationUpdate(version: version, commit: String(repeating: "a", count: 40), dirty: false, packagePath: package.path)
        let manifest = update.manifestURL(in: root)
        try FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(update).write(to: manifest)
        return update
    }
    @MainActor func testDiscoveryAndCancellationKeepStagedUpdate() async throws {
        try await fixture { root in
            _ = try publish("9.1", root: root)
            let latest = try publish("10.1", root: root)
            let outside = PendingApplicationUpdate(version: "99", commit: "outside", dirty: false, packagePath: root.path)
            try JSONEncoder().encode(outside).write(to: outside.manifestURL(in: root))
            try expectEqual(PendingApplicationUpdate.latest(in: root), latest)
            let current = ApplicationUpdates(directory: root, currentVersion: "10.1")
            try expectNil(current.pending)
            let installer = RecordingUpdateInstaller()
            let updates = ApplicationUpdates(directory: root, target: root.appendingPathComponent("Installed.app"), installer: installer)
            installer.failPrepare = true
            try expectThrows(try updates.requestInstallation())
            try expectFalse(updates.isRequested)
            installer.failPrepare = false
            try updates.requestInstallation(); try updates.requestInstallation()
            try expectEqual(installer.preparations, 1)
            updates.cancelInstallation()
            try updates.scheduleIfRequested(afterExitOf: 123)
            try expectEqual(installer.schedules, 0)
            try expectEqual(installer.discards, 1)
            try expectFalse(updates.isRequested)
            try expectEqual(PendingApplicationUpdate.latest(in: root), latest)
            try updates.requestInstallation()
            installer.failSchedule = true
            try expectThrows(try updates.scheduleIfRequested(afterExitOf: 123))
            try expectTrue(updates.isRequested)
            updates.cancelInstallation()
            installer.failSchedule = false
            try updates.requestInstallation()
            try updates.scheduleIfRequested(afterExitOf: 123)
            try updates.scheduleIfRequested(afterExitOf: 123)
            try expectEqual(installer.schedules, 1)
            try expectFalse(updates.isRequested)
            try expectTrue(FileManager.default.fileExists(atPath: latest.manifestURL(in: root).path))
        }
    }
    private func signedBundle(_ url: URL, version: String, identifier: String = "dev.asyncstudio.macos", executable: String = "/usr/bin/true") throws {
        let binaries = url.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: binaries, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: executable), to: binaries.appendingPathComponent("AsyncDevStudio"))
        let info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleExecutable": "AsyncDevStudio", "CFBundlePackageType": "APPL",
                                   "CFBundleVersion": version, "StudioBuildCommit": String(repeating: "b", count: 40), "StudioBuildDirty": true]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: url.appendingPathComponent("Contents/Info.plist"))
        try run("/usr/bin/codesign", ["--force", "--sign", "-", url.path])
    }
    @discardableResult private func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = errors; process.standardError = errors
        try process.run()
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ApplicationUpdateError.failed(String(decoding: data, as: UTF8.self)) }
        return String(decoding: data, as: UTF8.self)
    }
    private func version(_ bundle: URL) throws -> String {
        let data = try Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))
        return (try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any])["CFBundleVersion"] as! String
    }
    private func opener(in root: URL) throws -> URL {
        let url = root.appendingPathComponent("open-probe")
        let text = """
        #!/bin/sh
        root=$(dirname -- "$0")
        version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$2/Contents/Info.plist")
        printf '%s\\n' "$version" >> "$root/opened"
        if [ "$version" = 2 ] && [ -f "$root/fail-new" ]; then exit 1; fi
        """
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !predicate() {
            guard Date() < deadline else { throw ApplicationUpdateError.failed("Timed out waiting for update helper") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
    func testInstallerWaitsThenInstallsAndPreservesBackup() async throws {
        try await fixture { root in
            let update = try publish("2", root: root)
            try signedBundle(update.packageURL, version: "2")
            let target = root.appendingPathComponent("Installed ' $().app", isDirectory: true)
            try signedBundle(target, version: "1")
            let installer = SystemApplicationUpdateInstaller(script: script, opener: try opener(in: root))
            let cancelled = try installer.prepare(update, target: target, manifest: update.manifestURL(in: root), result: root.appendingPathComponent("error"))
            installer.discard(cancelled)
            try expectFalse(FileManager.default.fileExists(atPath: cancelled.directory.path))
            try expectEqual(try version(target), "1")
            try expectTrue(FileManager.default.fileExists(atPath: update.manifestURL(in: root).path))
            let transaction = try installer.prepare(update, target: target, manifest: update.manifestURL(in: root), result: root.appendingPathComponent("error"))
            let parent = Process(); parent.executableURL = URL(fileURLWithPath: "/bin/sleep"); parent.arguments = ["30"]
            try parent.run(); defer { if parent.isRunning { parent.terminate() } }
            try installer.schedule(transaction, afterExitOf: parent.processIdentifier)
            try await Task.sleep(nanoseconds: 200_000_000)
            try expectEqual(try version(target), "1")
            try expectFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("opened").path))
            parent.terminate()
            while parent.isRunning { try await Task.sleep(nanoseconds: 10_000_000) }
            try await waitUntil { !FileManager.default.fileExists(atPath: update.manifestURL(in: root).path) }
            try expectEqual(try version(target), "2")
            try expectEqual(try version(transaction.directory.appendingPathComponent("previous.app")), "1")
            try expectEqual(try version(update.packageURL), "2")
            try expectEqual(try String(contentsOf: root.appendingPathComponent("opened")), "2\n")
            let build = ApplicationBuild(bundle: Bundle(url: target)!)
            try expectEqual(build.commit, String(repeating: "b", count: 40))
            try expectTrue(build.isDirty)
            try expectTrue(build.label.contains("local changes"))
        }
    }
    func testDetachedInstallerSurvivesHangupBeforeApplicationExit() async throws {
        try await fixture { root in
            let update = try publish("2", root: root)
            try signedBundle(update.packageURL, version: "2")
            let target = root.appendingPathComponent("Installed.app", isDirectory: true)
            try signedBundle(target, version: "1")
            let installer = SystemApplicationUpdateInstaller(script: script, opener: try opener(in: root))
            let transaction = try installer.prepare(update, target: target, manifest: update.manifestURL(in: root), result: root.appendingPathComponent("error"))
            let parent = Process(); parent.executableURL = URL(fileURLWithPath: "/bin/sleep"); parent.arguments = ["30"]
            try parent.run(); defer { if parent.isRunning { parent.terminate() } }
            // schedule returns after the short-lived launcher exits; installation is detached.
            try installer.schedule(transaction, afterExitOf: parent.processIdentifier)
            let pidText = try String(contentsOf: transaction.directory.appendingPathComponent("helper.pid")).trimmingCharacters(in: .whitespacesAndNewlines)
            let pid = Int32(pidText)!
            let owner = try run("/bin/ps", ["-p", String(pid), "-o", "ppid="]).trimmingCharacters(in: .whitespacesAndNewlines)
            try expectEqual(owner, "1") // launchd, rather than Terminal or the launching app
            try expectEqual(kill(pid, SIGHUP), 0)
            try await Task.sleep(nanoseconds: 200_000_000)
            try expectEqual(kill(pid, 0), 0)
            try expectEqual(try version(target), "1")
            try expectEqual(try String(contentsOf: transaction.directory.appendingPathComponent("status.txt")), "waiting\n")
            parent.terminate()
            while parent.isRunning { try await Task.sleep(nanoseconds: 10_000_000) }
            try await waitUntil { !FileManager.default.fileExists(atPath: update.manifestURL(in: root).path) }
            try expectEqual(try version(target), "2")
            try expectEqual(try String(contentsOf: root.appendingPathComponent("opened")), "2\n")
            try expectFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("error").path))
            try await waitUntil { kill(pid, 0) != 0 }
        }
    }

    func testInstallerAlsoWaitsForLiveTargetThroughPathAliases() async throws {
        try await fixture { root in
            let update = try publish("2", root: root)
            try signedBundle(update.packageURL, version: "2")
            let target = root.appendingPathComponent("Installed.app", isDirectory: true)
            try signedBundle(target, version: "1", executable: "/bin/sleep")
            let running = Process()
            running.executableURL = target.appendingPathComponent("Contents/MacOS/AsyncDevStudio")
            running.arguments = ["30"]
            try running.run(); defer { if running.isRunning { running.terminate() } }
            let runningIDs = try run("/bin/sh", [script.path, "--running-pids"]).split(whereSeparator: \.isWhitespace)
            try expectTrue(runningIDs.contains(Substring(String(running.processIdentifier))))
            let installer = SystemApplicationUpdateInstaller(script: script, opener: try opener(in: root))
            let transaction = try installer.prepare(update, target: target, manifest: update.manifestURL(in: root), result: root.appendingPathComponent("error"))
            // Even if the initiating PID already exited, a live installed copy must block replacement.
            let parent = Process(); parent.executableURL = URL(fileURLWithPath: "/usr/bin/true")
            try parent.run(); parent.waitUntilExit()
            try installer.schedule(transaction, afterExitOf: parent.processIdentifier)
            try await Task.sleep(nanoseconds: 200_000_000)
            try expectTrue(running.isRunning)
            try expectEqual(try version(target), "1")
            try expectFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("opened").path))
            running.terminate()
            while running.isRunning { try await Task.sleep(nanoseconds: 10_000_000) }
            try await waitUntil { !FileManager.default.fileExists(atPath: update.manifestURL(in: root).path) }
            try expectEqual(try version(target), "2")
        }
    }

    func testFailedRelaunchRollsBackAndKeepsPendingUpdate() async throws {
        try await fixture { root in
            let update = try publish("2", root: root)
            try signedBundle(update.packageURL, version: "2")
            let target = root.appendingPathComponent("Installed.app", isDirectory: true)
            try signedBundle(target, version: "1")
            try Data().write(to: root.appendingPathComponent("fail-new"))
            let installer = SystemApplicationUpdateInstaller(script: script, opener: try opener(in: root))
            let result = root.appendingPathComponent("error")
            let transaction = try installer.prepare(update, target: target, manifest: update.manifestURL(in: root), result: result)
            let parent = Process(); parent.executableURL = URL(fileURLWithPath: "/usr/bin/true")
            try parent.run(); parent.waitUntilExit()
            try installer.schedule(transaction, afterExitOf: parent.processIdentifier)
            try await waitUntil { FileManager.default.fileExists(atPath: result.path) }
            try expectEqual(try version(target), "1")
            try expectEqual(try String(contentsOf: root.appendingPathComponent("opened")), "2\n1\n")
            try expectTrue(FileManager.default.fileExists(atPath: update.manifestURL(in: root).path))
            try expectTrue(try String(contentsOf: result).contains("previous application was kept"))
            try expectTrue(FileManager.default.fileExists(atPath: transaction.directory.appendingPathComponent("failed.app").path))
        }
    }
    func testRejectsTamperedBundlesAndUnrelatedTargets() async throws {
        try await fixture { root in
            let update = try publish("2", root: root)
            try signedBundle(update.packageURL, version: "2")
            let installer = SystemApplicationUpdateInstaller(script: script)
            let target = root.appendingPathComponent("Unrelated.app", isDirectory: true)
            try signedBundle(target, version: "1", identifier: "example.unrelated")
            try expectThrows(try installer.prepare(update, target: target, manifest: update.manifestURL(in: root), result: root.appendingPathComponent("error")))
            try expectEqual(try version(target), "1")
            try FileManager.default.removeItem(at: target)
            let current = root.appendingPathComponent("Current.app", isDirectory: true)
            try signedBundle(current, version: "2")
            try expectThrows(try installer.prepare(update, target: current, manifest: update.manifestURL(in: root), result: root.appendingPathComponent("error")))
            try expectEqual(try version(current), "2")
            try Data("tampered".utf8).write(to: update.packageURL.appendingPathComponent("Contents/MacOS/AsyncDevStudio"))
            try expectThrows(try installer.prepare(update, target: target, manifest: update.manifestURL(in: root), result: root.appendingPathComponent("error")))
            try expectFalse(FileManager.default.fileExists(atPath: target.path))
        }
    }
}
private final class RecordingUpdateInstaller: ApplicationUpdateInstalling {
    var preparations = 0, schedules = 0, discards = 0
    var failSchedule = false, failPrepare = false
    func prepare(_ update: PendingApplicationUpdate, target: URL, manifest: URL, result: URL) throws -> ApplicationUpdateTransaction {
        if failPrepare { throw ApplicationUpdateError.unavailable }
        preparations += 1
        return ApplicationUpdateTransaction(directory: target.deletingLastPathComponent().appendingPathComponent("transaction"), target: target, manifest: manifest, result: result, version: update.version)
    }
    func schedule(_ transaction: ApplicationUpdateTransaction, afterExitOf processID: Int32) throws {
        if failSchedule { throw ApplicationUpdateError.invalidProcess }
        schedules += 1
    }
    func discard(_ transaction: ApplicationUpdateTransaction) { discards += 1 }
}
