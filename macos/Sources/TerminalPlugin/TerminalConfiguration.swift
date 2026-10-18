import Foundation
import StudioKernel

public struct TerminalConfiguration: Codable, Equatable {
    public var version = 1
    public var shell: String
    public var workingDirectory: String
    public var startupCommands: [String]

    public init(shell: String = "/bin/zsh", workingDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path, startupCommands: [String] = []) {
        self.shell = shell; self.workingDirectory = workingDirectory; self.startupCommands = startupCommands
    }
    public func encoded() throws -> Data { try JSONEncoder().encode(self) }
    public static func decode(_ data: Data) throws -> Self { try JSONDecoder().decode(Self.self, from: data) }
    public func validate() throws {
        guard version == 1 else { throw TerminalError.invalidConfiguration("Unsupported terminal configuration version.") }
        guard shell.hasPrefix("/"), !shell.contains("\0"), FileManager.default.isExecutableFile(atPath: shell) else {
            throw TerminalError.invalidConfiguration("Choose an executable shell using its absolute path.")
        }
        var isDirectory: ObjCBool = false
        guard workingDirectory.hasPrefix("/"), !workingDirectory.contains("\0"),
              FileManager.default.fileExists(atPath: workingDirectory, isDirectory: &isDirectory), isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: workingDirectory) else {
            throw TerminalError.invalidConfiguration("Choose an accessible working directory using its absolute path.")
        }
        guard !startupCommands.contains(where: { $0.contains("\0") }) else {
            throw TerminalError.invalidConfiguration("Startup commands cannot contain null characters.")
        }
    }
    public var arguments: [String] { ["-il"] }

    /// Queue one compound command for the interactive shell to read after its
    /// normal startup files. A second shell would lose functions/local variables
    /// and run initialization (including Conda base activation) again.
    var startupInput: Data {
        let commands = startupCommands.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !commands.isEmpty else { return Data() }
        let script = commands.map { "{\n\($0)\n} || exit $?" }.joined(separator: "\n")
        return Data(("{\n" + script + "\n}\n").utf8)
    }
}

public final class TerminalPlugin: TerminalAppPlugin {
    public init() { super.init(id: "terminal", name: "Terminal") }
    public override var supportsStartupCommands: Bool { true }
    public override func decodeConfiguration(_ data: Data) throws -> TerminalConfiguration { try TerminalConfiguration.decode(data) }
    public override func configurationData(shell: String, workingDirectory: String, startupCommands: [String]) throws -> Data {
        try TerminalConfiguration(shell: shell, workingDirectory: workingDirectory, startupCommands: startupCommands).encoded()
    }
}

public enum TerminalError: Error, LocalizedError {
    case invalidConfiguration(String)
    case system(String, Int32)
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message): return message
        case .system(let operation, let code): return "\(operation): \(String(cString: strerror(code)))"
        }
    }
}
