import Foundation
import StudioKernel
import AppKit
import PDFKit
@testable import EditorPlugin

final class EditorTests {
    func testPDFExportReplacementAndContainment() throws {
        try fixture { root in
            let fs = try DiskEditorFileSystem(folder: root)
            let destination = root.appendingPathComponent("notes.pdf")
            try fs.writeExport(Data("old".utf8), to: destination)
            try fs.writeExport(Data("new".utf8), to: destination)
            try expectEqual(try Data(contentsOf: destination), Data("new".utf8))
            try fixture { outside in
                let external = try file("external.pdf", "keep", at: outside)
                try FileManager.default.removeItem(at: destination)
                try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: external)
                try fs.writeExport(Data("replacement".utf8), to: destination)
                try expectEqual(try Data(contentsOf: destination), Data("replacement".utf8))
                try expectEqual(try String(contentsOf: external, encoding: .utf8), "keep")
                try expectThrows(try fs.writeExport(Data(), to: external))
                let link = root.appendingPathComponent("outside")
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
                try expectThrows(try fs.writeExport(Data(), to: link.appendingPathComponent("external.pdf")))
            }
            let directory = root.appendingPathComponent("folder.pdf", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            _ = try file("keep.txt", "keep", at: directory)
            try expectThrows(try fs.writeExport(Data(), to: directory))
            try expectEqual(try String(contentsOf: directory.appendingPathComponent("keep.txt"), encoding: .utf8), "keep")
            try expectFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasSuffix(".pdf-export") })
        }
    }
    @MainActor func testNativeMarkdownPDFUsesCurrentBufferAndReplacesSibling() throws {
        _ = NSApplication.shared
        try fixture { root in
            let folder = root.appendingPathComponent("notes", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let source = try file("release.notes.MD", "# Original", at: folder)
            let destination = try file("release.notes.pdf", "old PDF", at: folder)
            let editor = try EditorWorkspace(folder: root)
            editor.setDirectoryExpanded(try editor.fileSystem.canonicalFile(folder), expanded: true)
            let document = try editor.openFile(source)
            document.updateText("# Current draft\n\nA **bold** and *italic* paragraph with `code`.\n\n- First item\n- Second item\n\n```swift\nlet answer = 42\n```\n\n| Name | Value |\n| --- | ---: |\n| Export | Ready |")
            document.selection = NSRange(location: 3, length: 2)
            let exported = try editor.convertToPDF(document)
            try expectEqual(exported.path, try editor.fileSystem.canonicalFile(destination).path)
            let pdf = PDFDocument(url: exported)
            try expectNotNil(pdf)
            let text = pdf?.string ?? ""
            for expected in ["Current draft", "bold", "italic", "First item", "Second item", "let answer = 42", "Name", "Export", "Ready"] {
                try expectTrue(text.contains(expected))
            }
            try expectFalse(text.contains("# Current draft"))
            try expectFalse(text.contains("**bold**"))
            try expectFalse(text.contains("Original"))
            try expectEqual(try String(contentsOf: source, encoding: .utf8), "# Original")
            try expectTrue(document.isDirty)
            try expectEqual(document.savedText, "# Original")
            try expectEqual(document.selection, NSRange(location: 3, length: 2))
            try expectEqual(editor.selectedID, document.id)
            try expectEqual(editor.documents.count, 1)
            try expectTrue(editor.listing[document.url.deletingLastPathComponent()]?.contains { $0.name == "release.notes.pdf" } == true)
            document.updateText("# Replacement draft")
            _ = try editor.convertToPDF(document)
            try expectTrue(PDFDocument(url: exported)?.string?.contains("Replacement draft") == true)
            try expectFalse(PDFDocument(url: exported)?.string?.contains("Current draft") == true)
        }
    }
    @MainActor func testNativeMarkdownPDFPaginationAndEmptyDocuments() throws {
        _ = NSApplication.shared
        let paragraphs = (1...100).map { "## Section \($0)\n\nParagraph \($0): A long document must keep its full text across page boundaries, including this paragraph’s final words." }
        let data = try MarkdownPDFRenderer.render("# Long document\n\n" + paragraphs.joined(separator: "\n\n") + "\n\nFinal sentinel", title: "Long document")
        let pdf = PDFDocument(data: data)
        try expectTrue((pdf?.pageCount ?? 0) > 1)
        let text = pdf?.string ?? ""
        for index in 1...100 {
            try expectTrue(text.contains("Paragraph \(index):"))
            let headingPage = (0..<(pdf?.pageCount ?? 0)).compactMap { pdf?.page(at: $0)?.string }
                .first { $0.components(separatedBy: .newlines).contains("Section \(index)") }
            try expectTrue(headingPage?.contains("Paragraph \(index):") == true)
        }
        try expectTrue(text.contains("Final sentinel"))
        let empty = PDFDocument(data: try MarkdownPDFRenderer.render("", title: "Empty"))
        try expectEqual(empty?.pageCount, 1)
    }
    @MainActor func testNativeMarkdownPDFFailureKeepsFilesAndBuffer() throws {
        _ = NSApplication.shared
        try fixture { root in
            let source = try file("notes.md", "# Saved", at: root)
            let destination = try file("notes.pdf", "existing PDF", at: root)
            let editor = try EditorWorkspace(fileSystem: FailingEditorFileSystem(base: DiskEditorFileSystem(folder: root)))
            let document = try editor.openFile(source)
            document.updateText("# Unsaved")
            try expectThrows(try editor.convertToPDF(document))
            try expectEqual(try String(contentsOf: destination, encoding: .utf8), "existing PDF")
            try expectEqual(try String(contentsOf: source, encoding: .utf8), "# Saved")
            try expectEqual(document.text, "# Unsaved")
            try expectTrue(document.isDirty)
            let plain = try editor.openFile(file("plain.txt", "text", at: root))
            try expectFalse(plain.isMarkdown)
            try expectThrows(try editor.convertToPDF(plain))
            try expectFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("plain.pdf").path))
        }
    }
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
    @MainActor func testDirectoryExpansionSurvivesCollapseAndRefresh() throws {
        try fixture { root in
            let editor = try EditorWorkspace(folder: root)
            let folder = editor.root.appendingPathComponent("src", isDirectory: true)
            let nested = folder.appendingPathComponent("nested", isDirectory: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            _ = try file("a.txt", "a", at: nested)
            editor.refresh()
            try expectNil(editor.listing[folder])
            editor.setDirectoryExpanded(folder, expanded: true)
            editor.setDirectoryExpanded(nested, expanded: true)
            try expectEqual(editor.listing[nested]?.map(\.name), ["a.txt"])
            editor.setDirectoryExpanded(folder, expanded: false)
            try expectFalse(editor.expandedDirectories.contains(folder))
            try expectTrue(editor.expandedDirectories.contains(nested))
            editor.setDirectoryExpanded(folder, expanded: true)
            _ = try file("b.txt", "b", at: nested)
            editor.refresh()
            try expectEqual(editor.expandedDirectories, Set([folder, nested]))
            try expectEqual(editor.listing[nested]?.map(\.name), ["a.txt", "b.txt"])
            editor.setDirectoryExpanded(nested, expanded: false)
            try expectEqual(editor.expandedDirectories, Set([folder]))
        }
    }
    @MainActor func testDirectoryExpansionIsRetainedPerEditorInstance() throws {
        try fixture { root in
            let folder = root.appendingPathComponent("src", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let configuration = try EditorConfiguration(folder: root.path).encoded()
            let first = AppInstance(appTypeID: "editor", name: "First", configuration: configuration)
            let second = AppInstance(appTypeID: "editor", name: "Second", configuration: configuration)
            let runtime = EditorRuntime()
            try runtime.open(first)
            let editor = runtime.controllers[first.id]!
            let canonicalFolder = editor.root.appendingPathComponent("src", isDirectory: true)
            editor.setDirectoryExpanded(canonicalFolder, expanded: true)
            try runtime.open(second)
            try expectTrue(runtime.controllers[second.id]!.expandedDirectories.isEmpty)
            try runtime.open(first)
            try expectTrue(runtime.controllers[first.id] === editor)
            try expectEqual(editor.expandedDirectories, Set([canonicalFolder]))
            runtime.controllers[second.id]!.setDirectoryExpanded(canonicalFolder, expanded: true)
            editor.setDirectoryExpanded(canonicalFolder, expanded: false)
            try expectTrue(editor.expandedDirectories.isEmpty)
            try expectEqual(runtime.controllers[second.id]!.expandedDirectories, Set([canonicalFolder]))
        }
    }
    func testRenameValidatesNamesAndDoesNotOverwrite() throws {
        try fixture { root in
            let fs = try DiskEditorFileSystem(folder: root)
            let source = try file("source.txt", "source", at: fs.root)
            let existing = try file("existing.txt", "keep", at: fs.root)
            for name in ["", ".", "..", "../escape", "bad/name", "bad\0name", "existing.txt"] {
                try expectThrows(try fs.rename(source, to: name))
            }
            let dangling = fs.root.appendingPathComponent("dangling.txt")
            try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: fs.root.appendingPathComponent("missing"))
            try expectThrows(try fs.rename(source, to: "dangling.txt"))
            try expectTrue((try? FileManager.default.destinationOfSymbolicLink(atPath: dangling.path)) != nil)
            try expectEqual(try String(contentsOf: existing), "keep")
            try expectEqual(try String(contentsOf: source), "source")
            try expectThrows(try fs.rename(fs.root, to: "renamed"))
            try expectThrows(try fs.trash(fs.root))
            let renamed = try fs.rename(source, to: "renamed.txt")
            try expectFalse(FileManager.default.fileExists(atPath: source.path))
            try expectEqual(try String(contentsOf: renamed), "source")
            try expectEqual(try fs.rename(renamed, to: "renamed.txt"), renamed)
            let caseRenamed = try fs.rename(renamed, to: "Renamed.txt")
            try expectEqual(caseRenamed.lastPathComponent, "Renamed.txt")
            try expectEqual(try String(contentsOf: caseRenamed), "source")
        }
    }
    func testMutatingSymlinkAffectsLinkAndRejectsOutsideParents() throws {
        try fixture { root in
            try fixture { outside in
                let fs = try DiskEditorFileSystem(folder: root)
                let target = try file("outside.txt", "private", at: outside)
                let link = fs.root.appendingPathComponent("link.txt")
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
                let renamed = try fs.rename(link, to: "renamed-link.txt")
                try expectEqual(try FileManager.default.destinationOfSymbolicLink(atPath: renamed.path), target.path)
                try expectEqual(try String(contentsOf: target), "private")
                try expectThrows(try fs.rename(target, to: "outside-renamed.txt"))
                try expectThrows(try fs.trash(target))
                let directoryLink = fs.root.appendingPathComponent("outside-folder")
                try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: outside)
                try expectThrows(try fs.rename(directoryLink.appendingPathComponent("outside.txt"), to: "escape.txt"))
                try expectThrows(try fs.trash(directoryLink.appendingPathComponent("outside.txt")))
            }
        }
    }
    @MainActor func testFolderRenameKeepsOpenBuffersAndExpandedTree() throws {
        try fixture { root in
            let editor = try EditorWorkspace(folder: root)
            let source = editor.root.appendingPathComponent("src", isDirectory: true)
            let nested = source.appendingPathComponent("nested", isDirectory: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            let doc = try editor.openFile(file("a.txt", "original", at: nested))
            let sibling = try editor.openFile(file("src-other.txt", "other", at: editor.root))
            doc.updateText("unsaved"); doc.selection = NSRange(location: 2, length: 1)
            editor.selectedID = doc.id
            editor.setDirectoryExpanded(source, expanded: true)
            editor.setDirectoryExpanded(nested, expanded: true)
            try editor.rename(source, to: "renamed")
            let destination = editor.root.appendingPathComponent("renamed", isDirectory: true)
            let movedNested = destination.appendingPathComponent("nested", isDirectory: true)
            try expectEqual(doc.url.path, movedNested.appendingPathComponent("a.txt").path)
            try expectEqual(doc.text, "unsaved"); try expectTrue(doc.isDirty)
            try expectEqual(doc.selection, NSRange(location: 2, length: 1))
            try expectEqual(editor.selectedID, doc.id)
            try expectEqual(editor.expandedDirectories, Set([destination, movedNested]))
            try expectEqual(editor.listing[movedNested]?.map(\.name), ["a.txt"])
            try expectNil(editor.listing[source])
            try expectEqual(sibling.url.lastPathComponent, "src-other.txt")
            try expectEqual(try editor.openFile(doc.url).id, doc.id)
            try expectEqual(editor.documents.count, 2)
            try editor.save(doc)
            try expectEqual(try String(contentsOf: doc.url), "unsaved")
        }
    }
    @MainActor func testDeleteRequiresDiscardAndClosesOnlyAffectedTabs() throws {
        try fixture { root in
            let fs = try MutationEditorFileSystem(root: root)
            let editor = try EditorWorkspace(fileSystem: fs)
            let folder = fs.root.appendingPathComponent("src", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let first = try editor.openFile(file("a.txt", "disk", at: folder))
            _ = try editor.openFile(file("b.txt", "b", at: folder))
            let other = try editor.openFile(file("src-other.txt", "keep", at: fs.root))
            first.updateText("unsaved"); editor.selectedID = first.id
            editor.setDirectoryExpanded(folder, expanded: true)
            try expectThrows(try editor.delete(folder))
            try expectEqual(editor.documents.count, 3)
            try expectTrue(fs.trashed.isEmpty)
            try editor.delete(folder, discardChanges: true)
            try expectEqual(editor.documents.map(\.id), [other.id])
            try expectEqual(editor.selectedID, other.id)
            try expectFalse(editor.expandedDirectories.contains(folder))
            try expectNil(editor.listing[folder])
            try expectFalse(FileManager.default.fileExists(atPath: folder.path))
            try expectEqual(try String(contentsOf: fs.trashed[0].appendingPathComponent("a.txt")), "disk")
            try expectEqual(try String(contentsOf: other.url), "keep")
            try editor.delete(other.url)
            try expectTrue(editor.documents.isEmpty); try expectNil(editor.selectedID)
        }
    }
    @MainActor func testFailedRenameAndTrashPreserveWorkspace() throws {
        try fixture { root in
            let fs = try MutationEditorFileSystem(root: root)
            let editor = try EditorWorkspace(fileSystem: fs)
            let doc = try editor.openFile(file("a.txt", "original", at: fs.root))
            let originalURL = doc.url
            doc.updateText("unsaved")
            fs.failMutation = true
            try expectThrows(try editor.rename(doc.url, to: "renamed.txt"))
            try expectThrows(try editor.delete(doc.url, discardChanges: true))
            try expectEqual(editor.documents.map(\.id), [doc.id])
            try expectEqual(editor.selectedID, doc.id)
            try expectEqual(doc.url, originalURL)
            try expectEqual(doc.text, "unsaved"); try expectTrue(doc.isDirty)
            try expectEqual(try String(contentsOf: doc.url), "original")
            try expectTrue(fs.trashed.isEmpty)
        }
    }
    @MainActor func testNativeRenamePreservesSurfaceUndoAndCaret() throws {
        _ = NSApplication.shared
        try fixture { root in
            let editor = try EditorWorkspace(folder: root)
            let doc = try editor.openFile(file("before.txt", "original", at: editor.root))
            let surface = EditorTextSurface(document: doc); doc.surface = surface
            surface.textView.undoManager?.beginUndoGrouping()
            surface.textView.insertText(" edit", replacementRange: NSRange(location: 8, length: 0))
            surface.textView.undoManager?.endUndoGrouping()
            let selection = surface.textView.selectedRange()
            try editor.rename(doc.url, to: "after.swift")
            try expectTrue(doc.surface === surface)
            try expectEqual(surface.textView.selectedRange(), selection)
            try expectEqual(surface.textView.accessibilityLabel(), "after.swift")
            try expectEqual(doc.text, "original edit")
            surface.textView.undoManager?.undo()
            try expectEqual(doc.text, "original")
            surface.textView.undoManager?.redo()
            try editor.save(doc)
            try expectEqual(try String(contentsOf: doc.url), "original edit")
        }
    }

    @MainActor func testTreeRefreshDoesNotReopenClosedDeletedFiles() throws {
        try fixture { root in
            let fs = try MutationEditorFileSystem(root: root)
            let editor = try EditorWorkspace(fileSystem: fs)
            let closed = try editor.openFile(file("closed.txt", "closed", at: fs.root))
            let other = try editor.openFile(file("other.txt", "keep", at: fs.root))
            other.updateText("unsaved edits")
            try expectTrue(try editor.closeFile(closed.id, decision: .discard))
            try FileManager.default.removeItem(at: closed.url)
            let reads = fs.reads
            editor.refresh()
            try expectNil(editor.error)
            try expectEqual(fs.reads, reads)
            try expectEqual(editor.documents.map(\.id), [other.id])
            try expectEqual(editor.selectedID, other.id)
            try expectEqual(other.text, "unsaved edits")
            try expectEqual(editor.listing[fs.root]?.map(\.name), ["other.txt"])
            try expectTrue(try editor.closeFile(other.id, decision: .discard))
            try FileManager.default.removeItem(at: other.url)
            editor.refresh()
            try expectNil(editor.error)
            try expectTrue(editor.documents.isEmpty)
            try expectNil(editor.selectedID)
            try expectEqual(fs.reads, reads)
        }
    }
    @MainActor func testTreeRefreshPrunesExternallyRemovedDirectories() throws {
        try fixture { root in
            let editor = try EditorWorkspace(folder: root)
            let folder = editor.root.appendingPathComponent("removed", isDirectory: true)
            let nested = folder.appendingPathComponent("nested", isDirectory: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            let doc = try editor.openFile(file("closed.txt", "closed", at: nested))
            editor.setDirectoryExpanded(folder, expanded: true)
            editor.setDirectoryExpanded(nested, expanded: true)
            // A visited folder remains cached even after its disclosure is closed.
            editor.setDirectoryExpanded(folder, expanded: false)
            try expectTrue(try editor.closeFile(doc.id, decision: .discard))
            try FileManager.default.removeItem(at: folder)
            editor.refresh()
            try expectNil(editor.error)
            try expectTrue(editor.documents.isEmpty)
            try expectNil(editor.selectedID)
            try expectNil(editor.listing[folder])
            try expectNil(editor.listing[nested])
            try expectTrue(editor.expandedDirectories.isEmpty)
            try expectEqual(editor.listing[editor.root]?.count, 0)
            editor.refresh()
            try expectNil(editor.error)
        }
    }

    @MainActor func testTreeRefreshReportsReadFailuresWithoutLosingBuffersOrTree() throws {
        try fixture { root in
            let fs = try MutationEditorFileSystem(root: root)
            let editor = try EditorWorkspace(fileSystem: fs)
            let folder = fs.root.appendingPathComponent("restricted", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let doc = try editor.openFile(file("open.txt", "disk", at: folder))
            doc.updateText("unsaved edits")
            editor.setDirectoryExpanded(folder, expanded: true)
            let listing = editor.listing
            fs.failListingAt = folder
            editor.refresh()
            try expectTrue(editor.error?.contains("Couldn’t refresh files in") == true)
            try expectEqual(editor.listing, listing)
            try expectTrue(editor.expandedDirectories.contains(folder))
            try expectEqual(editor.documents.map(\.id), [doc.id])
            try expectEqual(editor.selectedID, doc.id)
            try expectEqual(doc.text, "unsaved edits")
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
    @MainActor func testRefreshFromDiskKeepsTabsAndUpdatesSaveBaseline() throws {
        try fixture { root in
            let url = try file("a.txt", "original", at: root)
            let editor = try EditorWorkspace(folder: root)
            let doc = try editor.openFile(url)
            let other = try editor.openFile(file("b.txt", "other", at: root))
            other.updateText("other edits")
            editor.selectedID = doc.id
            let disk = Data([0xff, 0xfe]) + "Updated 🌍".data(using: .utf16LittleEndian)!
            try disk.write(to: url)
            try editor.reload(doc, discardChanges: false)
            try expectEqual(doc.text, "Updated 🌍")
            try expectFalse(doc.isDirty)
            try expectEqual(editor.selectedID, doc.id)
            try expectEqual(editor.documents.map(\.id), [doc.id, other.id])
            try expectEqual(other.text, "other edits")
            try expectTrue(other.isDirty)
            doc.updateText("Saved after refresh")
            try editor.save(doc)
            try expectEqual(try Data(contentsOf: url), Data([0xff, 0xfe]) + "Saved after refresh".data(using: .utf16LittleEndian)!)
        }
    }
    @MainActor func testFailedRefreshKeepsUnsavedBuffer() throws {
        try fixture { root in
            let url = try file("a.txt", "original", at: root)
            let editor = try EditorWorkspace(folder: root)
            let doc = try editor.openFile(url)
            doc.updateText("unsaved edits")
            doc.selection = NSRange(location: 4, length: 2)
            try Data([0, 1, 255]).write(to: url)
            try expectThrows(try editor.reload(doc, discardChanges: true))
            try expectEqual(doc.text, "unsaved edits")
            try expectEqual(doc.savedText, "original")
            try expectTrue(doc.isDirty)
            try expectEqual(doc.selection, NSRange(location: 4, length: 2))
            try FileManager.default.removeItem(at: url)
            try expectThrows(try editor.reload(doc, discardChanges: true))
            try expectEqual(doc.text, "unsaved edits")
            try expectEqual(editor.selectedID, doc.id)
        }
    }
    @MainActor func testNativeRefreshReplacesVisibleTextAndClearsUndo() throws {
        _ = NSApplication.shared
        try fixture { root in
            let url = try file("a.swift", "let original = 1", at: root)
            let editor = try EditorWorkspace(folder: root)
            let doc = try editor.openFile(url)
            let surface = EditorTextSurface(document: doc)
            doc.surface = surface
            surface.textView.undoManager?.beginUndoGrouping()
            surface.textView.insertText("local edit", replacementRange: NSRange(location: 0, length: 0))
            surface.textView.undoManager?.endUndoGrouping()
            try expectTrue(doc.isDirty)
            try expectTrue(surface.textView.undoManager?.canUndo == true)
            try Data("let disk = 2".utf8).write(to: url)
            try editor.reload(doc, discardChanges: true)
            try expectEqual(surface.textView.string, "let disk = 2")
            try expectEqual(doc.text, "let disk = 2")
            try expectFalse(doc.isDirty)
            try expectFalse(surface.textView.undoManager?.canUndo == true)
            try expectEqual(surface.textView.selectedRange(), NSRange(location: 0, length: 0))
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
    func testCreateFolderRejectsCollisionsAndInvalidLocations() throws {
        try fixture { root in
            let fs = try DiskEditorFileSystem(folder: root)
            let folder = try fs.createFolder(name: "New folder", in: fs.root)
            try expectTrue(try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
            let child = try file("keep.txt", "keep", at: folder)
            let existing = try file("existing.txt", "original", at: fs.root)
            let link = fs.root.appendingPathComponent("dangling")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fs.root.appendingPathComponent("missing"))
            for name in ["New folder", "existing.txt", "dangling", "", ".", "..", "../escape", "a/b", "bad\0name"] {
                try expectThrows(try fs.createFolder(name: name, in: fs.root))
            }
            try expectEqual(try String(contentsOf: child), "keep")
            try expectEqual(try String(contentsOf: existing), "original")
            try expectTrue((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil)
            try expectThrows(try fs.createFolder(name: "child", in: existing))
            try fixture { outside in
                try expectThrows(try fs.createFolder(name: "escape", in: outside))
                let alias = fs.root.appendingPathComponent("outside")
                try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outside)
                try expectThrows(try fs.createFolder(name: "escape", in: alias))
                try expectFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("escape").path))
            }
        }
    }
    @MainActor func testCreateFolderRevealsParentAndKeepsOpenDocuments() throws {
        try fixture { root in
            let editor = try EditorWorkspace(folder: root)
            let parent = editor.root.appendingPathComponent("Parent", isDirectory: true)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let doc = try editor.openFile(file("open.txt", "disk", at: editor.root))
            doc.updateText("unsaved")
            editor.refresh()
            try expectFalse(editor.expandedDirectories.contains(parent))
            let folder = try editor.createFolder(name: "Child", in: parent)
            try expectTrue(editor.expandedDirectories.contains(parent))
            let entries = editor.listing[parent]!
            try expectEqual(entries.map(\.name), ["Child"])
            try expectTrue(entries[0].isDirectory)
            try expectEqual(entries[0].url, folder)
            try expectEqual(editor.documents.map(\.id), [doc.id])
            try expectEqual(editor.selectedID, doc.id)
            try expectEqual(doc.text, "unsaved")
            try expectTrue(doc.isDirty)
            _ = try editor.createFolder(name: "Root child", in: editor.root)
            try expectTrue(editor.listing[editor.root]?.contains { $0.name == "Root child" && $0.isDirectory } == true)
            let listing = editor.listing
            try expectThrows(try editor.createFolder(name: "Child", in: parent))
            try expectEqual(editor.listing, listing)
            try expectEqual(editor.selectedID, doc.id)
        }
    }
    @MainActor func testFailedFolderCreationKeepsWorkspace() throws {
        try fixture { root in
            let fs = try MutationEditorFileSystem(root: root)
            let editor = try EditorWorkspace(fileSystem: fs)
            let doc = try editor.openFile(file("open.txt", "disk", at: fs.root))
            doc.updateText("unsaved")
            let listing = editor.listing
            let expanded = editor.expandedDirectories
            fs.failMutation = true
            try expectThrows(try editor.createFolder(name: "Denied", in: fs.root))
            try expectEqual(editor.listing, listing)
            try expectEqual(editor.expandedDirectories, expanded)
            try expectEqual(editor.selectedID, doc.id)
            try expectEqual(doc.text, "unsaved")
            try expectFalse(FileManager.default.fileExists(atPath: fs.root.appendingPathComponent("Denied").path))
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

    @MainActor func testNativeHomeAndEndMoveWithinCurrentLine() throws {
        _ = NSApplication.shared
        try fixture { root in
            for (index, newline) in ["\n", "\r\n"].enumerated() {
                let text = "first\(newline)    ab🌍cd\(newline)\(newline)last\(newline)"
                let editor = try EditorWorkspace(folder: root)
                let doc = try editor.openFile(file("keys\(index).txt", text, at: root))
                let surface = EditorTextSurface(document: doc)
                let view = surface.textView
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
                window.isReleasedWhenClosed = false
                defer { window.close() }
                window.contentView = surface
                window.makeFirstResponder(view)
                @MainActor func press(_ key: UInt16, shift: Bool = false) {
                    var flags: NSEvent.ModifierFlags = [.function, .numericPad]
                    if shift { flags.insert(.shift) }
                    let character = String(UnicodeScalar(key == 115 || key == 123 ? NSHomeFunctionKey : NSEndFunctionKey)!)
                    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                        timestamp: 0, windowNumber: window.windowNumber, context: nil,
                        characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: key)!
                    view.keyDown(with: event)
                }
                let line = (text as NSString).range(of: "    ab🌍cd")
                let middle = line.location + 6
                view.setSelectedRange(NSRange(location: middle, length: 0))
                press(115)
                try expectEqual(view.selectedRange(), NSRange(location: line.location, length: 0))
                press(119)
                try expectEqual(view.selectedRange(), NSRange(location: NSMaxRange(line), length: 0))
                view.setSelectedRange(NSRange(location: middle, length: 0))
                press(115, shift: true)
                try expectEqual(view.selectedRange(), NSRange(location: line.location, length: middle - line.location))
                view.setSelectedRange(NSRange(location: middle, length: 0))
                press(119, shift: true)
                try expectEqual(view.selectedRange(), NSRange(location: middle, length: NSMaxRange(line) - middle))
                for position in [NSMaxRange(line) + (newline as NSString).length, (text as NSString).length] {
                    view.setSelectedRange(NSRange(location: position, length: 0))
                    press(115); press(119)
                    try expectEqual(view.selectedRange(), NSRange(location: position, length: 0))
                }
                // Fn-arrow events can retain the physical arrow key codes.
                view.setSelectedRange(NSRange(location: middle, length: 0))
                press(123)
                try expectEqual(view.selectedRange(), NSRange(location: line.location, length: 0))
                press(124)
                try expectEqual(view.selectedRange(), NSRange(location: NSMaxRange(line), length: 0))
                view.setSelectedRange(NSRange(location: 0, length: 0))
                press(115); press(119)
                try expectEqual(view.selectedRange(), NSRange(location: 5, length: 0))
                try expectEqual(doc.text, text)
                try expectFalse(doc.isDirty)
            }
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
    func writeExport(_ data: Data, to url: URL) throws { throw CocoaError(.fileWriteNoPermission) }
    func create(name: String, in directory: URL) throws -> URL { try base.create(name: name, in: directory) }
    func createFolder(name: String, in directory: URL) throws -> URL { try base.createFolder(name: name, in: directory) }
    func rename(_ url: URL, to name: String) throws -> URL { try base.rename(url, to: name) }
    func trash(_ url: URL) throws { try base.trash(url) }
}

/// Route successful trash operations to a disposable test directory, not the user's Trash.
private final class MutationEditorFileSystem: EditorFileSystem {
    let base: DiskEditorFileSystem
    let trashDirectory: URL
    var failMutation = false
    var reads: [URL] = []
    var failListingAt: URL?
    var trashed: [URL] = []
    var root: URL { base.root }
    init(root: URL) throws {
        let folder = root.appendingPathComponent("workspace", isDirectory: true)
        trashDirectory = root.appendingPathComponent("trash", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
        base = try DiskEditorFileSystem(folder: folder)
    }
    func canonicalFile(_ url: URL) throws -> URL { try base.canonicalFile(url) }
    func entries(in directory: URL) throws -> [EditorEntry] {
        if directory.path == failListingAt?.path { throw CocoaError(.fileReadNoPermission) }
        return try base.entries(in: directory)
    }
    func read(_ url: URL) throws -> Data { reads.append(url); return try base.read(url) }
    func write(_ data: Data, to url: URL, replacing expected: Data) throws { try base.write(data, to: url, replacing: expected) }
    func writeExport(_ data: Data, to url: URL) throws { try base.writeExport(data, to: url) }
    func create(name: String, in directory: URL) throws -> URL { try base.create(name: name, in: directory) }
    func createFolder(name: String, in directory: URL) throws -> URL {
        if failMutation { throw CocoaError(.fileWriteNoPermission) }
        return try base.createFolder(name: name, in: directory)
    }
    func rename(_ url: URL, to name: String) throws -> URL {
        if failMutation { throw CocoaError(.fileWriteNoPermission) }
        return try base.rename(url, to: name)
    }
    func trash(_ url: URL) throws {
        if failMutation { throw CocoaError(.fileWriteNoPermission) }
        let destination = trashDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.moveItem(at: canonicalEntry(url), to: destination)
        trashed.append(destination)
    }
}
