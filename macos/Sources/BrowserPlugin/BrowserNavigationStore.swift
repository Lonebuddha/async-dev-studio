import Foundation

public struct BrowserNavigationStore {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    public func load(profileID: UUID) throws -> URL? {
        let data: Data
        do { data = try Data(contentsOf: file(profileID)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        let address = try JSONDecoder().decode(String.self, from: data)
        return try BrowserConfiguration.normalizedURL(address)
    }
    public func save(_ url: URL, profileID: UUID) throws {
        _ = try BrowserConfiguration.normalizedURL(url.absoluteString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(url.absoluteString).write(to: file(profileID), options: .atomic)
    }
    public func delete(profileID: UUID) throws {
        do { try FileManager.default.removeItem(at: file(profileID)) }
        catch let error as CocoaError where error.code == .fileNoSuchFile { return }
    }
    private func file(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }
}
