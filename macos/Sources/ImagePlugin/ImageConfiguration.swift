import Foundation
import StudioKernel

public struct ImageConfiguration: Codable, Equatable {
    public var version = 1
    public var folder: String
    public init(folder: String = FileManager.default.homeDirectoryForCurrentUser.path) { self.folder = folder }
    public func validate() throws {
        guard version == 1, folder.hasPrefix("/") else { throw ImageError.invalidFolder }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &directory), directory.boolValue,
              FileManager.default.isReadableFile(atPath: folder) else { throw ImageError.invalidFolder }
    }
    public func encoded() throws -> Data { try JSONEncoder().encode(self) }
    public static func decode(_ data: Data) throws -> Self { try JSONDecoder().decode(Self.self, from: data) }
}
public struct ImagePlugin: AppPlugin {
    public let descriptor = AppDescriptor(id: "images", name: "Image Viewer")
    public init() {}
    public func validate(configuration: Data) throws { try ImageConfiguration.decode(configuration).validate() }
}
public enum ImageError: Error, LocalizedError {
    case invalidFolder, outsideFolder, unsupportedImage
    public var errorDescription: String? {
        switch self {
        case .invalidFolder: return "Choose an existing, readable folder with an absolute path."
        case .outsideFolder: return "This path is outside the image viewer’s configured folder."
        case .unsupportedImage: return "This image could not be opened. It may be damaged or unsupported."
        }
    }
}
