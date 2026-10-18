import Foundation
import StudioKernel
import TerminalPlugin

public final class ClaudePlugin: TerminalAppPlugin {
    public let sessions: ClaudeSessionStore
    private let executable: String
    public override var configurationSummary: String? {
        "Claude Code starts automatically and resumes this instance’s saved conversation."
    }
    public init(sessions: ClaudeSessionStore = ClaudeSessionStore(), executable: String = "claude") {
        self.sessions = sessions
        self.executable = executable
        super.init(id: "claude", name: "Claude")
    }
    public override func decodeConfiguration(_ data: Data) throws -> TerminalConfiguration {
        try ClaudeConfiguration.decode(data).terminalConfiguration
    }
    public override func configurationData(shell: String, workingDirectory: String, startupCommands: [String]) throws -> Data {
        try ClaudeConfiguration(shell: shell, workingDirectory: workingDirectory).encoded()
    }
    public override func launchConfiguration(for instance: AppInstance) throws -> TerminalConfiguration {
        var configuration = try decodeConfiguration(instance.configuration)
        let sessionID = try sessions.sessionID(for: instance.id, workingDirectory: configuration.workingDirectory)
        let settings = try sessions.hookSettings(for: instance.id)
        var command = "exec " + ClaudeSessionStore.quote(executable)
            + " --permission-mode bypassPermissions --settings " + ClaudeSessionStore.quote(settings)
        if let sessionID { command += " --resume " + ClaudeSessionStore.quote(sessionID.uuidString.lowercased()) }
        configuration.startupCommands = [command]
        return configuration
    }
}
