import Foundation
import TerminalPlugin

/// Only the CLI's session metadata is stored here. Claude owns its conversation history.
public struct ClaudeSessionStore {
    public let directory: URL
    public init(directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/AsyncDevStudio/ClaudeSessions")) { self.directory = directory }

    public func recordURL(for instanceID: UUID) -> URL {
        directory.appendingPathComponent(instanceID.uuidString).appendingPathComponent("session.json")
    }

    public func sessionID(for instanceID: UUID, workingDirectory: String) throws -> UUID? {
        let data: Data
        do { data = try Data(contentsOf: recordURL(for: instanceID)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        let record = try JSONDecoder().decode(Record.self, from: data)
        guard let id = UUID(uuidString: record.session_id) else {
            throw TerminalError.invalidConfiguration("The saved Claude session ID is invalid.")
        }
        guard URL(fileURLWithPath: record.cwd).standardizedFileURL.resolvingSymlinksInPath()
                == URL(fileURLWithPath: workingDirectory).standardizedFileURL.resolvingSymlinksInPath() else { return nil }
        // Exiting an empty conversation can leave no transcript to resume.
        guard record.transcript_path.hasPrefix("/") else {
            throw TerminalError.invalidConfiguration("The saved Claude transcript path is invalid.")
        }
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: record.transcript_path) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        guard let size = attributes[.size] as? NSNumber, size.uint64Value > 0 else { return nil }
        return id
    }

    public func hookSettings(for instanceID: UUID) throws -> String {
        let record = recordURL(for: instanceID)
        let folder = record.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Each callback publishes atomically using a unique temporary file.
        // SessionStart also fires on /clear and /resume, tracking the latest conversation.
        let command = "umask 077; studio_record_tmp=$(/usr/bin/mktemp " + Self.quote(folder.appendingPathComponent(".hook.XXXXXX").path)
            + ") || exit 1; /bin/cat > \"$studio_record_tmp\" && /bin/mv -f \"$studio_record_tmp\" " + Self.quote(record.path)
            + "; studio_record_status=$?; /bin/rm -f \"$studio_record_tmp\"; exit $studio_record_status"
        let settings: [String: Any] = ["hooks": ["SessionStart": [["hooks": [["type": "command", "command": command, "timeout": 5]]]]]]
        return String(decoding: try JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys]), as: UTF8.self)
    }

    public static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private struct Record: Decodable {
        let session_id: String
        let transcript_path: String
        let cwd: String
    }
}
