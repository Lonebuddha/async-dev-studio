import Foundation
import StudioKernel
import AppKit
@testable import EditorPlugin

final class EditorTests {
    private func fixture(_ test: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try test(root)
    }
    private func file(_ name: String, _ text: String, at root: URL) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }
    func testConfigurationAndInstancePersistence() throws {
        try fixture { root in
            try EditorConfiguration(folder: root.path).validate()
            try expectThrows(try EditorConfiguration(folder: "relative").validate())
            try expectThrows(try EditorConfiguration(folder: root.appendingPathComponent("missing").path).validate())
            let file = try file("file.txt", "hi", at: root)
            try expectThrows(try EditorConfiguration(folder: file.path).validate())
            let registry = PluginRegistry(); try registry.register(EditorPlugin())
            let store = JSONProjectStore(fileURL: root.appendingPathComponent("workspace.json"))
            let kernel = try ProjectKernel(store: store, plugins: registry)
            let project = try kernel.createProject(name: "Code")
            let instance = try kernel.createInstance(projectID: project.id, appTypeID: "editor", name: "Sources", configuration: EditorConfiguration(folder: root.path).encoded())
            let restored = try ProjectKernel(store: store, plugins: registry)
            try expectEqual(restored.projects[0].instances, [instance])
        }
    }
    func testDirectoryListingAndSymlinkContainment() throws {
        try fixture { root in
            try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
            _ = try file("z.txt", "z", at: root); _ = try file(".hidden", "h", at: root)
            let fs = try DiskEditorFileSystem(folder: root)
            try expectEqual(try fs.entries(in: fs.root).map(\.name), ["src", ".hidden", "z.txt"])
            try fixture { outside in
                let external = try file("outside.txt", "private", at: outside)
                let link = root.appendingPathComponent("link.txt")
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
                try expectThrows(try fs.read(link))
                try expectThrows(try fs.entries(in: outside))
            }
        }
    }
    @MainActor func testTabsAndIndependentInstances() throws {
        try fixture { root in
            let first = try file("a.txt", "alpha", at: root), second = try file("b.txt", "beta", at: root)
            let editor = try EditorWorkspace(folder: root)
            let a = try editor.openFile(first), b = try editor.openFile(second)
            try expectEqual(editor.documents.count, 2)
            try expectEqual(editor.selectedID, b.id)
            try expectEqual(try editor.openFile(first).id, a.id)
            try expectEqual(editor.documents.count, 2)
            let other = try EditorWorkspace(folder: root)
            let otherA = try other.openFile(first)
            a.updateText("changed")
            try expectEqual(otherA.text, "alpha")
        }
    }
    @MainActor func testDirtyStateAndSave() throws {
        try fixture { root in
            let url = try file("a.txt", "alpha\r\n", at: root)
            let editor = try EditorWorkspace(folder: root); let doc = try editor.openFile(url)
            doc.updateText("beta\r\n"); try expectTrue(doc.isDirty)
            doc.updateText("alpha\r\n"); try expectFalse(doc.isDirty)
            doc.updateText("beta\r\n"); try editor.save(doc)
            try expectFalse(doc.isDirty)
            try expectEqual(String(decoding: Data(contentsOf: url), as: UTF8.self), "beta\r\n")
        }
    }
    @MainActor func testSaveDiscardCancelOnClose() throws {
        try fixture { root in
            let url = try file("a.txt", "original", at: root)
            let editor = try EditorWorkspace(folder: root); var doc = try editor.openFile(url)
            doc.updateText("edited")
            try expectFalse(try editor.closeFile(doc.id, decision: .cancel)); try expectEqual(editor.documents.count, 1)
            try expectTrue(try editor.closeFile(doc.id, decision: .discard))
            try expectEqual(String(decoding: Data(contentsOf: url), as: UTF8.self), "original")
            doc = try editor.openFile(url); doc.updateText("saved")
            try expectTrue(try editor.closeFile(doc.id, decision: .save))
            try expectEqual(String(decoding: Data(contentsOf: url), as: UTF8.self), "saved")
        }
    }
    @MainActor func testExternalChangesAndReload() throws {
        try fixture { root in
            let url = try file("a.txt", "original", at: root)
            let editor = try EditorWorkspace(folder: root); let doc = try editor.openFile(url)
            doc.updateText("local")
            try Data("external".utf8).write(to: url)
            try expectThrows(try editor.save(doc)); try expectTrue(doc.isDirty)
            try expectEqual(String(decoding: Data(contentsOf: url), as: UTF8.self), "external")
            try expectThrows(try editor.reload(doc, discardChanges: false))
            try editor.reload(doc, discardChanges: true)
            try expectEqual(doc.text, "external"); try expectFalse(doc.isDirty)
        }
    }
    @MainActor func testEncodingAndBinaryRejection() throws {
        try fixture { root in
            let url = root.appendingPathComponent("utf16.txt")
            let initial = Data([0xff, 0xfe]) + "Hello 🌍".data(using: .utf16LittleEndian)!
            try initial.write(to: url)
            let editor = try EditorWorkspace(folder: root); let doc = try editor.openFile(url)
            try expectEqual(doc.text, "Hello 🌍")
            doc.updateText("Edited 🌍"); try editor.save(doc)
            try expectEqual(try Data(contentsOf: url), Data([0xff, 0xfe]) + "Edited 🌍".data(using: .utf16LittleEndian)!)
            let binary = root.appendingPathComponent("binary.dat")
            try Data([0, 1, 255]).write(to: binary)
            try expectThrows(try editor.openFile(binary))
            try expectEqual(editor.documents.count, 1)
        }
    }
    @MainActor func testCreateFileWithoutOverwriting() throws {
        try fixture { root in
            let editor = try EditorWorkspace(folder: root)
            let doc = try editor.createFile(name: "new.txt", in: root)
            try expectEqual(doc.text, ""); try expectFalse(doc.isDirty)
            doc.updateText("first"); try editor.save(doc)
            try expectThrows(try editor.createFile(name: "new.txt", in: root))
            try expectThrows(try editor.createFile(name: "../escape.txt", in: root))
            try expectEqual(String(decoding: Data(contentsOf: doc.url), as: UTF8.self), "first")
        }
    }
    @MainActor func testSaveFailureKeepsDirtyTab() throws {
        try fixture { root in
            let url = try file("a.txt", "original", at: root)
            let fs = FailingEditorFileSystem(base: try DiskEditorFileSystem(folder: root))
            let editor = try EditorWorkspace(fileSystem: fs); let doc = try editor.openFile(url)
            doc.updateText("local")
            try expectThrows(try editor.closeFile(doc.id, decision: .save))
            try expectTrue(doc.isDirty); try expectEqual(editor.documents.count, 1)
            try expectEqual(String(decoding: Data(contentsOf: url), as: UTF8.self), "original")
        }
    }
    @MainActor func testSavePreservesExecutablePermissions() throws {
        try fixture { root in
            let url = try file("script.sh", "echo before\n", at: root)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            let editor = try EditorWorkspace(folder: root); let doc = try editor.openFile(url)
            doc.updateText("echo after\n"); try editor.save(doc)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            try expectEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o755)
        }
    }

    @MainActor func testNativeEditingKeepsUndoSeparateAcrossTabs() throws {
        _ = NSApplication.shared
        try fixture { root in
            let first = try file("a.swift", "let a = 1", at: root), second = try file("b.swift", "let b = 2", at: root)
            let editor = try EditorWorkspace(folder: root)
            let a = try editor.openFile(first), b = try editor.openFile(second)
            let firstSurface = EditorTextSurface(document: a), secondSurface = EditorTextSurface(document: b)
            a.surface = firstSurface; b.surface = secondSurface
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            for (surface, doc) in [(firstSurface, a), (secondSurface, b)] {
                window.contentView = surface; window.makeFirstResponder(surface.textView)
                surface.textView.setSelectedRange(NSRange(location: (doc.text as NSString).length, length: 0))
                surface.textView.undoManager?.beginUndoGrouping()
                surface.textView.insertText(" // edit", replacementRange: surface.textView.selectedRange())
                surface.textView.undoManager?.endUndoGrouping()
                try expectTrue(doc.isDirty)
            }
            try expectTrue(firstSurface.textView.undoManager !== secondSurface.textView.undoManager)
            _ = try editor.openFile(first)
            window.contentView = firstSurface
            firstSurface.textView.undoManager?.undo()
            try expectEqual(a.text, "let a = 1"); try expectFalse(a.isDirty)
            try expectEqual(b.text, "let b = 2 // edit")
            firstSurface.textView.undoManager?.redo()
            try expectEqual(a.text, "let a = 1 // edit")
            try editor.save(a)
            try expectEqual(try String(contentsOf: first, encoding: .utf8), a.text)
        }
    }

    @MainActor func testNativeIndentationAndCRLF() throws {
        _ = NSApplication.shared
        try fixture { root in
            let editor = try EditorWorkspace(folder: root)
            let doc = try editor.openFile(file("a.swift", "    let x = 1\r\n    x", at: root))
            let surface = EditorTextSurface(document: doc)
            surface.textView.setSelectedRange(NSRange(location: (doc.text as NSString).length, length: 0))
            surface.textView.insertNewline(nil)
            try expectEqual(doc.text, "    let x = 1\r\n    x\r\n    ")
            surface.textView.insertTab(nil)
            try expectTrue(doc.text.hasSuffix("\r\n        "))
            try expectTrue(doc.isDirty)
            try editor.save(doc)
            try expectEqual(try String(contentsOf: doc.url, encoding: .utf8), doc.text)
        }
    }

    @MainActor func testCancelledWorkspaceCloseKeepsDocuments() throws {
        try fixture { root in
            let editor = try EditorWorkspace(folder: root)
            let first = try editor.openFile(file("a.txt", "a", at: root)), second = try editor.openFile(file("b.txt", "b", at: root))
            first.updateText("A"); second.updateText("B")
            var calls = 0
            let approved = try editor.prepareToClose { _ in calls += 1; return calls == 1 ? .discard : .cancel }
            try expectFalse(approved); try expectEqual(editor.documents.count, 2)
            try expectTrue(first.isDirty); try expectTrue(second.isDirty)
        }
    }
}
private final class FailingEditorFileSystem: EditorFileSystem {
    let base: DiskEditorFileSystem
    var root: URL { base.root }
    init(base: DiskEditorFileSystem) { self.base = base }
    func canonicalFile(_ url: URL) throws -> URL { try base.canonicalFile(url) }
    func entries(in directory: URL) throws -> [EditorEntry] { try base.entries(in: directory) }
    func read(_ url: URL) throws -> Data { try base.read(url) }
    func write(_ data: Data, to url: URL, replacing expected: Data) throws { throw CocoaError(.fileWriteNoPermission) }
    func create(name: String, in directory: URL) throws -> URL { try base.create(name: name, in: directory) }
}
