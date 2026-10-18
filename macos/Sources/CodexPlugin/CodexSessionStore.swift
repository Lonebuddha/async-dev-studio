import Foundation
import TerminalPlugin

/// Codex retains its own history; Studio stores only an instance's ID and folder.
public struct CodexSessionStore {
    public let directory: URL
    public init(directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/AsyncDevStudio/CodexSessions")) {
        self.directory = directory
    }
    public func recordURL(for instance: UUID) -> URL {
        directory.appendingPathComponent(instance.uuidString).appendingPathComponent("session.json")
    }
    public func sessionID(for instance: UUID, workingDirectory: String) throws -> UUID? {
        let data: Data
        do { data = try Data(contentsOf: recordURL(for: instance)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        let record = try JSONDecoder().decode(Record.self, from: data)
        guard let id = UUID(uuidString: record.session_id), record.cwd.hasPrefix("/") else {
            throw TerminalError.invalidConfiguration("The saved Codex session record is invalid.")
        }
        func canonical(_ path: String) -> URL {
            URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        }
        return canonical(record.cwd) == canonical(workingDirectory) ? id : nil
    }

    /// CLI -c accepts this TOML-compatible JSON array. The callback receives a
    /// JSON argument, never shell code. plutil is bundled with macOS.
    public func notificationConfiguration(for instance: UUID) throws -> String {
        let record = recordURL(for: instance)
        let folder = record.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let command = """
        umask 077
        studio_event=$(/usr/bin/printf '%s' "$1" | /usr/bin/plutil -extract type raw -o - -) || exit 1
        [ "$studio_event" = agent-turn-complete ] || exit 0
        studio_id=$(/usr/bin/printf '%s' "$1" | /usr/bin/plutil -extract thread-id raw -o - -) || exit 1
        studio_cwd=$(/usr/bin/printf '%s' "$1" | /usr/bin/plutil -extract cwd raw -o - -) || exit 1
        studio_tmp=$(/usr/bin/mktemp \(Self.quote(folder.appendingPathComponent(".notify.XXXXXX").path))) || exit 1
        trap '/bin/rm -f "$studio_tmp"' EXIT
        /usr/bin/plutil -create xml1 "$studio_tmp" &&
        /usr/bin/plutil -insert session_id -string "$studio_id" "$studio_tmp" &&
        /usr/bin/plutil -insert cwd -string "$studio_cwd" "$studio_tmp" &&
        /usr/bin/plutil -convert json "$studio_tmp" &&
        /bin/mv -f "$studio_tmp" \(Self.quote(record.path))
        """
        // Keep the startup line below the PTY canonical-input limit.
        let script = folder.appendingPathComponent("notify.sh")
        try Data(command.utf8).write(to: script, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: script.path)
        let arguments = ["/bin/sh", script.path]
        return "notify=" + String(decoding: try JSONSerialization.data(withJSONObject: arguments,
            options: [.withoutEscapingSlashes]), as: UTF8.self)
    }
    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    private struct Record: Decodable { let session_id: String; let cwd: String }
}
