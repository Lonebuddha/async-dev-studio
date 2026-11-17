import AppKit
import Combine
import Foundation

public struct ApplicationBuild: Equatable {
    public let version: String
    public let commit: String
    public let isDirty: Bool
    public init(bundle: Bundle = .main) {
        version = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Development"
        commit = bundle.object(forInfoDictionaryKey: "StudioBuildCommit") as? String ?? "Unknown commit"
        isDirty = bundle.object(forInfoDictionaryKey: "StudioBuildDirty") as? Bool ?? false
    }
    public var label: String { String(commit.prefix(12)) + (isDirty ? " + local changes" : "") + " · " + version }
}

public struct PendingApplicationUpdate: Codable, Equatable {
    public let version: String
    public let commit: String
    public let dirty: Bool
    public let packagePath: String
    public var packageURL: URL { URL(fileURLWithPath: packagePath, isDirectory: true) }
    public init(version: String, commit: String, dirty: Bool, packagePath: String) {
        self.version = version; self.commit = commit; self.dirty = dirty; self.packagePath = packagePath
    }
    public var label: String { String(commit.prefix(12)) + (dirty ? " + local changes" : "") }
    public func manifestURL(in directory: URL) -> URL { directory.appendingPathComponent("ready/\(version).json") }
    public static func latest(in directory: URL) -> Self? {
        let ready = directory.appendingPathComponent("ready", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: ready, includingPropertiesForKeys: nil) else { return nil }
        let packages = directory.appendingPathComponent("packages", isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        return files.filter { $0.pathExtension == "json" }.compactMap { file -> Self? in
            guard let data = try? Data(contentsOf: file), let update = try? JSONDecoder().decode(Self.self, from: data),
                  update.version == file.deletingPathExtension().lastPathComponent else { return nil }
            let package = update.packageURL.standardizedFileURL.resolvingSymlinksInPath()
            guard package.path.hasPrefix(packages.path + "/"), FileManager.default.fileExists(atPath: package.path) else { return nil }
            return update
        }.sorted { $0.version.compare($1.version, options: .numeric) == .orderedAscending }.last
    }
}

public struct ApplicationUpdateTransaction {
    public let directory: URL
    public let target: URL
    public let manifest: URL
    public let result: URL
    public let version: String
    public init(directory: URL, target: URL, manifest: URL, result: URL, version: String) {
        self.directory = directory; self.target = target; self.manifest = manifest; self.result = result; self.version = version
    }
}

public enum ApplicationUpdateError: Error, LocalizedError {
    case unavailable, invalidProcess, failed(String)
    public var errorDescription: String? {
        switch self {
        case .unavailable: return "No staged application update is available."
        case .invalidProcess: return "The running application could not be identified."
        case .failed(let message): return message
        }
    }
}
public protocol ApplicationUpdateInstalling {
    func prepare(_ update: PendingApplicationUpdate, target: URL, manifest: URL, result: URL) throws -> ApplicationUpdateTransaction
    func schedule(_ transaction: ApplicationUpdateTransaction, afterExitOf processID: Int32) throws
    func discard(_ transaction: ApplicationUpdateTransaction)
}

public struct SystemApplicationUpdateInstaller: ApplicationUpdateInstalling {
    private let script: URL?
    private let opener: URL
    public init(script: URL? = Bundle.main.url(forResource: "install-update", withExtension: "sh"), opener: URL = URL(fileURLWithPath: "/usr/bin/open")) {
        self.script = script; self.opener = opener
    }
    public func prepare(_ update: PendingApplicationUpdate, target: URL, manifest: URL, result: URL) throws -> ApplicationUpdateTransaction {
        guard let script else { throw ApplicationUpdateError.failed("The application updater is missing. Rebuild the application bundle.") }
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path, "--prepare", update.packagePath, target.path, update.version]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output; process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ApplicationUpdateError.failed("Couldn’t prepare the update. " + detail)
        }
        let path = String(decoding: data, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? ""
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        guard directory.deletingLastPathComponent().standardizedFileURL == target.deletingLastPathComponent().standardizedFileURL,
              directory.lastPathComponent.hasPrefix(".async-dev-studio-update.") else {
            throw ApplicationUpdateError.failed("The updater returned an invalid installation location.")
        }
        return ApplicationUpdateTransaction(directory: directory, target: target, manifest: manifest, result: result, version: update.version)
    }
    public func schedule(_ transaction: ApplicationUpdateTransaction, afterExitOf processID: Int32) throws {
        guard processID > 0 else { throw ApplicationUpdateError.invalidProcess }
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = [transaction.directory.appendingPathComponent("install-update.sh").path, "--commit", transaction.directory.path,
                            transaction.target.path, String(processID), transaction.manifest.path, transaction.version, opener.path, transaction.result.path]
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = FileHandle.nullDevice; helper.standardError = FileHandle.nullDevice
        try helper.run()
    }
    public func discard(_ transaction: ApplicationUpdateTransaction) {
        try? FileManager.default.removeItem(at: transaction.directory)
    }
}

/// Discovery never changes the installed app. Only approved shutdown schedules installation.
@MainActor
public final class ApplicationUpdates: ObservableObject {
    nonisolated public static var directory: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AsyncDevStudio/Updates", isDirectory: true) }
    nonisolated public static var installedApplication: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Async Dev Studio.app", isDirectory: true) }
    @Published public private(set) var pending: PendingApplicationUpdate?
    @Published public private(set) var failure: String?
    public var isRequested: Bool { transaction != nil }
    private let directory: URL
    private let target: URL
    private let currentVersion: String?
    private let installer: any ApplicationUpdateInstalling
    private var transaction: ApplicationUpdateTransaction?
    public init(directory: URL = ApplicationUpdates.directory, target: URL = ApplicationUpdates.installedApplication,
                installer: any ApplicationUpdateInstalling = SystemApplicationUpdateInstaller(),
                currentVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) {
        self.directory = directory; self.target = target; self.installer = installer; self.currentVersion = currentVersion
        failure = try? String(contentsOf: directory.appendingPathComponent("last-error.txt"), encoding: .utf8)
        refresh()
    }
    public func refresh() {
        var available = PendingApplicationUpdate.latest(in: directory)
        if let version = available?.version, let currentVersion,
           version.compare(currentVersion, options: .numeric) != .orderedDescending { available = nil }
        if pending != available { pending = available }
    }
    public func requestInstallation() throws {
        guard transaction == nil else { return }
        refresh()
        guard let pending else { throw ApplicationUpdateError.unavailable }
        transaction = try installer.prepare(pending, target: target, manifest: pending.manifestURL(in: directory), result: directory.appendingPathComponent("last-error.txt"))
    }
    public func cancelInstallation() {
        if let transaction { installer.discard(transaction) }
        transaction = nil
    }
    public func scheduleIfRequested(afterExitOf processID: Int32) throws {
        guard let transaction else { return }
        try installer.schedule(transaction, afterExitOf: processID)
        self.transaction = nil
    }
    public func dismissFailure() {
        failure = nil
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("last-error.txt"))
    }
}
