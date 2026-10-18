import Foundation

public struct RestartTarget: Equatable {
    public enum Kind: String { case bundle, executable }
    public let url: URL
    public let kind: Kind
    public init(url: URL, kind: Kind) { self.url = url.standardizedFileURL; self.kind = kind }
    public static func current() throws -> Self {
        guard let executable = Bundle.main.executableURL else { throw RestartError.missingExecutable }
        if Bundle.main.bundleURL.pathExtension == "app" {
            return Self(url: Bundle.main.bundleURL, kind: .bundle)
        }
        return Self(url: executable, kind: .executable)
    }
}
public enum RestartError: Error, LocalizedError {
    case missingExecutable, invalidProcess
    public var errorDescription: String? {
        switch self {
        case .missingExecutable: return "The application could not be found at its current location."
        case .invalidProcess: return "The current application process could not be identified."
        }
    }
}
public protocol RestartScheduling {
    func schedule(target: RestartTarget, afterExitOf processID: Int32) throws
}

/// Uses only system tools: no additional product executable or plugin is installed.
public struct RestartLauncher: RestartScheduling {
    private let bundleOpener: URL
    public init(bundleOpener: URL = URL(fileURLWithPath: "/usr/bin/open")) { self.bundleOpener = bundleOpener }
    public func schedule(target: RestartTarget, afterExitOf processID: Int32) throws {
        guard processID > 0 else { throw RestartError.invalidProcess }
        let executable: URL?
        switch target.kind {
        case .bundle: executable = Bundle(url: target.url)?.executableURL
        case .executable: executable = target.url
        }
        guard let executable, FileManager.default.isExecutableFile(atPath: executable.path) else { throw RestartError.missingExecutable }
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Arguments are positional data, never interpolated into shell source.
        // Wait for the old PID to exit so Launch Services cannot reactivate it.
        helper.arguments = ["-c", Self.script, "async-dev-studio-restart", String(processID), target.url.path, target.kind.rawValue, bundleOpener.path]
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        try helper.run()
    }
    private static let script = """
    parent_pid=$1
    target=$2
    kind=$3
    opener=$4
    attempts=0
    while kill -0 "$parent_pid" 2>/dev/null; do
        attempts=$((attempts + 1))
        if [ "$attempts" -ge 600 ]; then exit 1; fi
        /bin/sleep 0.1
    done
    if [ "$kind" = bundle ]; then
        exec "$opener" -n "$target"
    else
        exec "$target"
    fi
    """
}

/// A cancelled or failed normal shutdown must never leave a queued relaunch.
public final class RestartCoordinator {
    public private(set) var isRequested = false
    private let launcher: any RestartScheduling
    public init(launcher: any RestartScheduling = RestartLauncher()) { self.launcher = launcher }
    public func request() { isRequested = true }
    public func cancel() { isRequested = false }
    public func scheduleIfRequested(target: RestartTarget, processID: Int32) throws {
        guard isRequested else { return }
        try launcher.schedule(target: target, afterExitOf: processID)
        isRequested = false
    }
}
