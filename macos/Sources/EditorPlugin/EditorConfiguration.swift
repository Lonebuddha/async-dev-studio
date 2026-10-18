import Foundation
import StudioKernel

public struct EditorConfiguration: Codable, Equatable {
    public var version = 1
    public var folder: String
    public init(folder: String = FileManager.default.homeDirectoryForCurrentUser.path) { self.folder = folder }
    public func validate() throws {
        guard version == 1, folder.hasPrefix("/") else { throw EditorError.invalidFolder }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &directory), directory.boolValue,
              FileManager.default.isReadableFile(atPath: folder) else { throw EditorError.invalidFolder }
    }
    public func encoded() throws -> Data { try JSONEncoder().encode(self) }
    public static func decode(_ data: Data) throws -> Self { try JSONDecoder().decode(Self.self, from: data) }
}
public struct EditorPlugin: AppPlugin {
    public let descriptor = AppDescriptor(id: "editor", name: "Text Editor")
    public init() {}
    public func validate(configuration: Data) throws { try EditorConfiguration.decode(configuration).validate() }
}
public enum EditorError: Error, LocalizedError {
    case invalidFolder, outsideFolder, notText, tooLarge, changedOnDisk, unsavedChanges, invalidName
    public var errorDescription: String? {
        switch self {
        case .invalidFolder: return "Choose an existing, readable folder with an absolute path."
        case .outsideFolder: return "This path points outside the editor’s configured folder."
        case .notText: return "This file isn’t supported text. Use UTF-8 or UTF-16 with a byte-order mark."
        case .tooLarge: return "This basic editor supports files up to 10 MB."
        case .changedOnDisk: return "The file changed or was removed on disk. Your edits are still open. Compare with the disk version, or reload to discard your edits."
        case .unsavedChanges: return "Save or discard the file’s changes before reloading."
        case .invalidName: return "Enter a file name without slashes, not . or .. ."
        }
    }
}
