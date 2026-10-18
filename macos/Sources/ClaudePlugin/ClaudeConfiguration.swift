import Foundation
import TerminalPlugin

public struct ClaudeConfiguration: Codable, Equatable {
    public var version = 1
    public var shell: String
    public var workingDirectory: String
    public init(shell: String = "/bin/zsh", workingDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path) {
        self.shell = shell
        self.workingDirectory = workingDirectory
    }
    public func encoded() throws -> Data { try JSONEncoder().encode(self) }
    public static func decode(_ data: Data) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.version == 1 else { throw TerminalError.invalidConfiguration("Unsupported Claude configuration version.") }
        try value.terminalConfiguration.validate()
        return value
    }
    public var terminalConfiguration: TerminalConfiguration { TerminalConfiguration(shell: shell, workingDirectory: workingDirectory) }
}
