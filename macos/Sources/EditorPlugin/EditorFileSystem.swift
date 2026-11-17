import Darwin
import Foundation

public struct EditorEntry: Identifiable, Equatable {
    public var id: URL { url }
    public let url: URL
    public let name: String
    public let isDirectory: Bool
}
public protocol EditorFileSystem {
    var root: URL { get }
    func canonicalFile(_ url: URL) throws -> URL
    func entries(in directory: URL) throws -> [EditorEntry]
    func read(_ url: URL) throws -> Data
    func write(_ data: Data, to url: URL, replacing expected: Data) throws
    func writeExport(_ data: Data, to url: URL) throws
    func create(name: String, in directory: URL) throws -> URL
    func createFolder(name: String, in directory: URL) throws -> URL
    func rename(_ url: URL, to name: String) throws -> URL
    func trash(_ url: URL) throws
}
extension EditorFileSystem {
    // Resolve the parent, not the entry: mutating a symlink must affect the link.
    func canonicalEntry(_ url: URL) throws -> URL {
        guard url.isFileURL else { throw EditorError.outsideFolder }
        let entry = url.standardizedFileURL
        guard entry.path != root.path else { throw EditorError.rootMutation }
        let parent = try canonicalFile(entry.deletingLastPathComponent())
        return parent.appendingPathComponent(entry.lastPathComponent)
    }
}
public struct DiskEditorFileSystem: EditorFileSystem {
    public let root: URL
    private let manager = FileManager.default
    public init(folder: URL) throws {
        try EditorConfiguration(folder: folder.path).validate()
        root = folder.standardizedFileURL.resolvingSymlinksInPath()
    }
    public func canonicalFile(_ url: URL) throws -> URL {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.isFileURL, resolved.path == root.path || resolved.path.hasPrefix(root.path == "/" ? "/" : root.path + "/") else {
            throw EditorError.outsideFolder
        }
        return resolved
    }
    public func entries(in directory: URL) throws -> [EditorEntry] {
        let folder = try canonicalFile(directory)
        return try manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: []).map { url in
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            // Symlink directories appear as files: no recursive cycles or implicit outside traversal.
            let isDirectory = values.isDirectory == true && values.isSymbolicLink != true
            // FileManager may return /private/var for a /var parent. Keep tree
            // identities in the same namespace as the validated directory.
            let entryURL = folder.appendingPathComponent(url.lastPathComponent, isDirectory: isDirectory)
            return EditorEntry(url: entryURL, name: url.lastPathComponent, isDirectory: isDirectory)
        }.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
    public func read(_ url: URL) throws -> Data {
        let file = try canonicalFile(url)
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw EditorError.notText }
        guard (values.fileSize ?? 0) <= 10 * 1024 * 1024 else { throw EditorError.tooLarge }
        let data = try Data(contentsOf: file)
        guard data.count <= 10 * 1024 * 1024 else { throw EditorError.tooLarge }
        return data
    }
    public func write(_ data: Data, to url: URL, replacing expected: Data) throws {
        let file = try canonicalFile(url)
        let current: Data
        do { current = try read(file) } catch { throw EditorError.changedOnDisk }
        guard current == expected else { throw EditorError.changedOnDisk }
        let attributes = try manager.attributesOfItem(atPath: file.path)
        try data.write(to: file, options: .atomic)
        if let permissions = attributes[.posixPermissions] { try manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: file.path) }
    }
    public func create(name: String, in directory: URL) throws -> URL {
        try validateName(name)
        let folder = try canonicalFile(directory)
        let file = try canonicalFile(folder.appendingPathComponent(name))
        try Data().write(to: file, options: .withoutOverwriting)
        return file
    }
    public func writeExport(_ data: Data, to url: URL) throws {
        let destination = try canonicalEntry(url)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).pdf-export")
        defer { try? manager.removeItem(at: temporary) }
        try data.write(to: temporary, options: .withoutOverwriting)
        // Atomic rename replaces an existing file or symlink itself, never its target.
        // A directory or a failed write leaves the previous destination untouched.
        guard Darwin.rename(temporary.path, destination.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: destination.path])
        }
    }
    public func createFolder(name: String, in directory: URL) throws -> URL {
        try validateName(name)
        let parent = try canonicalFile(directory)
        let folder = parent.appendingPathComponent(name, isDirectory: true)
        // mkdir is exclusive: existing directories, files and symlinks all fail.
        guard mkdir(folder.path, 0o755) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: folder.path])
        }
        return folder
    }
    public func rename(_ url: URL, to name: String) throws -> URL {
        try validateName(name)
        let source = try canonicalEntry(url)
        let destination = source.deletingLastPathComponent().appendingPathComponent(name)
        guard source.path != destination.path else { return source }
        // moveItem fails if the destination exists; never replace another item.
        try manager.moveItem(at: source, to: destination)
        return destination
    }
    public func trash(_ url: URL) throws {
        try manager.trashItem(at: canonicalEntry(url), resultingItemURL: nil)
    }
    private func validateName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { throw EditorError.invalidName }
    }
}

struct TextEncoding {
    let encoding: String.Encoding
    let prefix: Data
    var label: String {
        switch encoding {
        case .utf16LittleEndian: return "UTF-16 LE"
        case .utf16BigEndian: return "UTF-16 BE"
        default: return prefix.isEmpty ? "UTF-8" : "UTF-8 BOM"
        }
    }
    static func decode(_ data: Data) throws -> (String, Self) {
        let format: Self
        if data.starts(with: [0xff, 0xfe]) { format = Self(encoding: .utf16LittleEndian, prefix: Data([0xff, 0xfe])) }
        else if data.starts(with: [0xfe, 0xff]) { format = Self(encoding: .utf16BigEndian, prefix: Data([0xfe, 0xff])) }
        else if data.starts(with: [0xef, 0xbb, 0xbf]) { format = Self(encoding: .utf8, prefix: Data([0xef, 0xbb, 0xbf])) }
        else { format = Self(encoding: .utf8, prefix: Data()) }
        guard let text = String(data: data.dropFirst(format.prefix.count), encoding: format.encoding),
              !text.unicodeScalars.contains(where: { $0.value == 0 || ($0.value < 32 && ![9, 10, 13].contains($0.value)) }) else { throw EditorError.notText }
        return (text, format)
    }
    func encode(_ text: String) throws -> Data {
        guard let data = text.data(using: encoding, allowLossyConversion: false) else { throw EditorError.notText }
        return prefix + data
    }
}
