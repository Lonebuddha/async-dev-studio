import Combine
import Foundation

public enum EditorCloseDecision { case save, discard, cancel }

@MainActor
public final class EditorDocument: ObservableObject, Identifiable {
    public let id = UUID()
    public let url: URL
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
    public func refresh() {
        for url in Array(listing.keys) { loadDirectory(url) }
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
