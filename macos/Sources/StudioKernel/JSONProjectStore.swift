import Foundation

/// An atomic, versioned local store for this small initial workspace.
/// Corrupt or newer files are reported rather than replaced with an empty workspace.
public struct JSONProjectStore: ProjectStore {
    public let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    public func load() throws -> [Project] {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard [1, 2].contains(document.version) else { throw StorageError.unsupportedVersion(document.version) }
        return document.projects
    }

    public func save(_ projects: [Project]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Document(version: 2, projects: projects))
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }

    private struct Document: Codable {
        let version: Int
        let projects: [Project]
    }

    private enum StorageError: LocalizedError {
        case unsupportedVersion(Int)
        var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let version):
                return "This workspace uses storage version \(version), which this application cannot read."
            }
        }
    }
}
