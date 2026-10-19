import Foundation
import StudioKernel
import TerminalPlugin

public final class CodexPlugin: TerminalAppPlugin {
    public let sessions: CodexSessionStore
    private let executable: String
    public override var configurationSummary: String? {
        "Codex starts automatically with unrestricted permissions and resumes this instance’s conversation after its first completed response."
    }
    public init(sessions: CodexSessionStore = CodexSessionStore(), executable: String = "codex") {
        self.sessions = sessions
        self.executable = executable
        super.init(id: "codex", name: "Codex")
    }
    public override func decodeConfiguration(_ data: Data) throws -> TerminalConfiguration {
        try CodexConfiguration.decode(data).terminalConfiguration
    }
    public override func configurationData(shell: String, workingDirectory: String, startupCommands: [String]) throws -> Data {
        try CodexConfiguration(shell: shell, workingDirectory: workingDirectory).encoded()
    }
    public override func launchConfiguration(for instance: AppInstance) throws -> TerminalConfiguration {
        var configuration = try decodeConfiguration(instance.configuration)
        let sessionID = try sessions.sessionID(for: instance.id, workingDirectory: configuration.workingDirectory)
        let notification = try sessions.notificationConfiguration(for: instance.id)
        var command = "exec " + CodexSessionStore.quote(executable)
        if let sessionID { command += " resume " + CodexSessionStore.quote(sessionID.uuidString.lowercased()) }
        command += " --no-alt-screen --dangerously-bypass-approvals-and-sandbox -c " + CodexSessionStore.quote(notification)
        configuration.startupCommands = [command]
        return configuration
    }
}
