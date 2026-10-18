import Foundation
import StudioPlatform

final class RestartTests {
    func testCancelAndOrdinaryQuitNeverScheduleRestart() throws {
        let launcher = RecordingRestartLauncher(), coordinator = RestartCoordinator(launcher: launcher)
        let target = RestartTarget(url: URL(fileURLWithPath: "/example/Studio.app"), kind: .bundle)
        try coordinator.scheduleIfRequested(target: target, processID: 123)
        try expectEqual(launcher.calls, 0)
        coordinator.request(); coordinator.cancel()
        try coordinator.scheduleIfRequested(target: target, processID: 123)
        try expectEqual(launcher.calls, 0)
        coordinator.request()
        try coordinator.scheduleIfRequested(target: target, processID: 123)
        try coordinator.scheduleIfRequested(target: target, processID: 123)
        try expectEqual(launcher.calls, 1)
        try expectEqual(launcher.target, target)
        try expectFalse(coordinator.isRequested)
    }
    func testLaunchFailureCanCancelAndRetry() throws {
        let launcher = RecordingRestartLauncher(), coordinator = RestartCoordinator(launcher: launcher)
        let target = RestartTarget(url: URL(fileURLWithPath: "/example/Studio.app"), kind: .bundle)
        launcher.fail = true; coordinator.request()
        try expectThrows(try coordinator.scheduleIfRequested(target: target, processID: 123))
        coordinator.cancel(); try expectFalse(coordinator.isRequested)
        launcher.fail = false; coordinator.request()
        try coordinator.scheduleIfRequested(target: target, processID: 123)
        try expectEqual(launcher.calls, 1)
    }
    func testRejectsMissingTargetAndInvalidPID() throws {
        let target = RestartTarget(url: URL(fileURLWithPath: "/nonexistent/Studio.app"), kind: .bundle)
        try expectThrows(try RestartLauncher().schedule(target: target, afterExitOf: 123))
        try expectThrows(try RestartLauncher().schedule(target: target, afterExitOf: 0))
    }
    func testBundleRelaunchUsesItsExactLocation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = directory.appendingPathComponent("Studio ' $().app")
        let contents = app.appendingPathComponent("Contents")
        let binaries = contents.appendingPathComponent("MacOS")
        try FileManager.default.createDirectory(at: binaries, withIntermediateDirectories: true)
        let info: [String: String] = ["CFBundleExecutable": "Probe", "CFBundleIdentifier": "dev.asyncstudio.restart-test", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        let probe = binaries.appendingPathComponent("Probe")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: probe)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: probe.path)
        let opener = directory.appendingPathComponent("open-probe")
        try Data("#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$(dirname -- \"$0\")/arguments\"\n".utf8).write(to: opener)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: opener.path)
        let parent = Process(); parent.executableURL = URL(fileURLWithPath: "/bin/sleep"); parent.arguments = ["10"]
        try parent.run()
        defer { if parent.isRunning { parent.terminate() } }
        try RestartLauncher(bundleOpener: opener).schedule(target: RestartTarget(url: app, kind: .bundle), afterExitOf: parent.processIdentifier)
        let marker = directory.appendingPathComponent("arguments")
        try await Task.sleep(nanoseconds: 200_000_000)
        try expectFalse(FileManager.default.fileExists(atPath: marker.path))
        parent.terminate()
        while parent.isRunning { try await Task.sleep(nanoseconds: 10_000_000) }
        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: marker.path), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        try expectTrue(FileManager.default.fileExists(atPath: marker.path))
        try expectEqual(try String(contentsOf: marker), "-n\n" + app.path + "\n")
    }

    func testWaitsForExitAndLaunchesExactExecutablePath() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("started")
        // Deliberately include characters that would be dangerous if interpolated into shell code.
        let executable = directory.appendingPathComponent("Studio ' $() executable")
        try Data("#!/bin/sh\nprintf '%s' launched > \"$(dirname -- \"$0\")/started\"\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let parent = Process(); parent.executableURL = URL(fileURLWithPath: "/bin/sleep"); parent.arguments = ["10"]
        try parent.run()
        defer { if parent.isRunning { parent.terminate() } }
        try RestartLauncher().schedule(target: RestartTarget(url: executable, kind: .executable), afterExitOf: parent.processIdentifier)
        try await Task.sleep(nanoseconds: 200_000_000)
        try expectFalse(FileManager.default.fileExists(atPath: marker.path))
        parent.terminate()
        while parent.isRunning { try await Task.sleep(nanoseconds: 10_000_000) }
        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: marker.path), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        try expectTrue(FileManager.default.fileExists(atPath: marker.path))
        try expectEqual(try String(contentsOf: marker), "launched")
    }
}
private final class RecordingRestartLauncher: RestartScheduling {
    var calls = 0
    var target: RestartTarget?
    var fail = false
    func schedule(target: RestartTarget, afterExitOf processID: Int32) throws {
        if fail { throw RestartError.missingExecutable }
        self.target = target; calls += 1
    }
}
