import Combine
import Foundation

public enum EditorCloseDecision { case save, discard, cancel }

@MainActor
public final class EditorDocument: ObservableObject, Identifiable {
    public let id = UUID()
    @Published public private(set) var url: URL
    @Published public private(set) var text: String
    @Published public private(set) var savedText: String
    @Published public var selection = NSRange(location: 0, length: 0)
    public var isDirty: Bool { text != savedText }
    public var encodingName: String { format.label }
    var diskData: Data
    var format: TextEncoding
    // Retains undo history, selection, and scroll position when another tab is selected.
    var surface: EditorTextSurface?
    init(url: URL, data: Data) throws {
        let (text, format) = try TextEncoding.decode(data)
        self.url = url; self.text = text; savedText = text; diskData = data; self.format = format
    }
    public func updateText(_ text: String) { if self.text != text { self.text = text } }
    func didSave(_ data: Data) { diskData = data; savedText = text }
    func didMove(to url: URL) {
        self.url = url
        surface?.refreshFileMetadata()
    }
    func didReload(_ data: Data) throws {
        let (text, format) = try TextEncoding.decode(data)
        self.format = format; diskData = data; savedText = text; self.text = text
        surface?.reset(text: text)
    }
}

@MainActor
public final class EditorWorkspace: ObservableObject {
    public let fileSystem: any EditorFileSystem
    public var root: URL { fileSystem.root }
    @Published public private(set) var documents: [EditorDocument] = []
    @Published public var selectedID: UUID?
    @Published public private(set) var listing: [URL: [EditorEntry]] = [:]
    // Keep tree expansion with the instance when SwiftUI recreates its pane.
    @Published public private(set) var expandedDirectories: Set<URL> = []
    @Published public var error: String?
    public var selectedDocument: EditorDocument? { documents.first { $0.id == selectedID } }
    public convenience init(folder: URL) throws { try self.init(fileSystem: DiskEditorFileSystem(folder: folder)) }
    public init(fileSystem: any EditorFileSystem) throws {
        self.fileSystem = fileSystem
        listing[fileSystem.root] = try fileSystem.entries(in: fileSystem.root)
    }
    public func loadDirectory(_ url: URL) {
        do { listing[url] = try fileSystem.entries(in: url) }
        catch { self.error = error.localizedDescription }
    }
    public func setDirectoryExpanded(_ url: URL, expanded: Bool) {
        if expanded {
            expandedDirectories.insert(url)
            loadDirectory(url)
        } else {
            expandedDirectories.remove(url)
        }
    }
    public func refresh() {
        // Refresh parents first. Cached children may have been removed by another
        // tool; only revisit directories still present in their parent's new list.
        let cached = Set(listing.keys).union(expandedDirectories)
        var refreshed: [URL: [EditorEntry]] = [:]
        var reachable: Set<URL> = [root]
        var pending: ArraySlice<URL> = [root]
        while let directory = pending.popFirst() {
            do {
                let entries = try fileSystem.entries(in: directory)
                refreshed[directory] = entries
                for entry in entries where entry.isDirectory {
                    reachable.insert(entry.url)
                    if cached.contains(entry.url) { pending.append(entry.url) }
                }
            } catch {
                self.error = "Couldn’t refresh files in \(directory.path): \(error.localizedDescription)"
                return
            }
        }
        listing = refreshed
        expandedDirectories = expandedDirectories.intersection(reachable)
    }
    @discardableResult public func openFile(_ url: URL) throws -> EditorDocument {
        let canonical = try fileSystem.canonicalFile(url)
        if let document = documents.first(where: { $0.url == canonical }) { selectedID = document.id; return document }
        let document = try EditorDocument(url: canonical, data: fileSystem.read(canonical))
        documents.append(document); selectedID = document.id
        return document
    }
    public func save(_ document: EditorDocument) throws {
        guard document.isDirty else { return }
        let data = try document.format.encode(document.text)
        guard data.count <= 10 * 1024 * 1024 else { throw EditorError.tooLarge }
        try fileSystem.write(data, to: document.url, replacing: document.diskData)
        document.didSave(data)
    }
    public func saveAll() throws { for document in documents { try save(document) } }
    public func reload(_ document: EditorDocument, discardChanges: Bool) throws {
        guard !document.isDirty || discardChanges else { throw EditorError.unsavedChanges }
        try document.didReload(fileSystem.read(document.url))
    }
    @discardableResult public func createFile(name: String, in directory: URL) throws -> EditorDocument {
        let url = try fileSystem.create(name: name, in: directory)
        loadDirectory(directory)
        return try openFile(url)
    }
    public func documents(inside url: URL) throws -> [EditorDocument] {
        let entry = try fileSystem.canonicalEntry(url)
        return documents.filter { Self.contains($0.url, in: entry) }
    }
    public func rename(_ url: URL, to name: String) throws {
        let source = try fileSystem.canonicalEntry(url)
        let destination = try fileSystem.rename(source, to: name)
        @MainActor func moved(_ url: URL) -> URL {
            guard Self.contains(url, in: source) else { return url }
            let suffix = String(url.path.dropFirst(source.path.count))
            return URL(fileURLWithPath: destination.path + suffix, isDirectory: url.hasDirectoryPath)
        }
        for document in documents where Self.contains(document.url, in: source) {
            document.didMove(to: moved(document.url))
        }
        expandedDirectories = Set(expandedDirectories.map(moved))
        let directories = listing.keys.map(moved)
        listing = [:]
        for directory in directories { loadDirectory(directory) }
    }
    public func delete(_ url: URL, discardChanges: Bool = false) throws {
        let source = try fileSystem.canonicalEntry(url)
        let affected = documents.filter { Self.contains($0.url, in: source) }
        guard discardChanges || !affected.contains(where: \.isDirty) else { throw EditorError.unsavedChanges }
        try fileSystem.trash(source)
        let selectedIndex = documents.firstIndex { $0.id == selectedID } ?? 0
        let removed = Set(affected.map(\.id))
        documents.removeAll { removed.contains($0.id) }
        if let selectedID, removed.contains(selectedID) {
            self.selectedID = documents.isEmpty ? nil : documents[min(selectedIndex, documents.count - 1)].id
        }
        expandedDirectories = expandedDirectories.filter { !Self.contains($0, in: source) }
        listing = listing.filter { !Self.contains($0.key, in: source) }
        refresh()
    }
    private static func contains(_ url: URL, in entry: URL) -> Bool {
        url.path == entry.path || url.path.hasPrefix(entry.path + "/")
    }
    @discardableResult public func closeFile(_ id: UUID, decision: EditorCloseDecision) throws -> Bool {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return true }
        let document = documents[index]
        if document.isDirty {
            switch decision {
            case .cancel: return false
            case .save: try save(document)
            case .discard: break
            }
        }
        documents.remove(at: index)
        if selectedID == id { selectedID = documents.isEmpty ? nil : documents[min(index, documents.count - 1)].id }
        return true
    }
    public func prepareToClose(decision: (EditorDocument) -> EditorCloseDecision) throws -> Bool {
        for document in documents where document.isDirty {
            switch decision(document) {
            case .cancel: return false
            case .save: try save(document)
            case .discard: break // Do not throw away edits until the entire close is approved.
            }
        }
        return true
    }
}
