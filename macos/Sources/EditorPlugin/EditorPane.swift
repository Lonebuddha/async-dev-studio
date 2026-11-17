import AppKit
import SwiftUI

public struct EditorPane: View {
    @ObservedObject private var workspace: EditorWorkspace
    public init(workspace: EditorWorkspace) { self.workspace = workspace }
    public var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                VStack(spacing: 0) {
                    HStack {
                        Text(workspace.root.lastPathComponent).font(.headline).lineLimit(1).help(workspace.root.path)
                            .contextMenu { EditorCreationMenu(workspace: workspace, directory: workspace.root) }
                        Spacer()
                        Button { workspace.refresh() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh files")
                        Button { newFile(in: workspace.root) } label: { Image(systemName: "doc.badge.plus") }.help("New file")
                    }.padding(8)
                    List {
                        EditorDirectoryRows(workspace: workspace, directory: workspace.root)
                    }.listStyle(.sidebar)
                }.frame(minWidth: 150, idealWidth: 220, maxWidth: 400)
                VStack(spacing: 0) {
                    if !workspace.documents.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 3) {
                                ForEach(workspace.documents) { document in
                                    EditorFileTab(workspace: workspace, document: document)
                                }
                            }.padding(5)
                        }
                        Divider()
                    }
                    if let document = workspace.selectedDocument {
                        EditorDocumentPane(workspace: workspace, document: document).id(document.id)
                    } else {
                        Text("Select a file to edit").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }.frame(minWidth: 250, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .alert("Couldn’t complete editor action", isPresented: Binding(get: { workspace.error != nil }, set: { if !$0 { workspace.error = nil } })) {
            Button("OK") { workspace.error = nil }
        } message: { Text(workspace.error ?? "") }
    }
    private func newFile(in directory: URL) { EditorActions.newFile(in: directory, workspace: workspace) }
}
private struct EditorDirectoryRows: View {
    @ObservedObject var workspace: EditorWorkspace
    let directory: URL
    var body: some View {
        ForEach(workspace.listing[directory] ?? []) { entry in
            if entry.isDirectory {
                EditorFolderRow(workspace: workspace, entry: entry)
            } else {
                Button {
                    do { try workspace.openFile(entry.url) } catch { workspace.error = error.localizedDescription }
                } label: {
                    Label(entry.name, systemImage: "doc.text").lineLimit(1).help(entry.url.path)
                }.buttonStyle(.plain)
                    .contextMenu { EditorEntryMenu(workspace: workspace, entry: entry) }
            }
        }
    }
}
private struct EditorFolderRow: View {
    @ObservedObject var workspace: EditorWorkspace
    let entry: EditorEntry
    private var expanded: Binding<Bool> {
        Binding(
            get: { workspace.expandedDirectories.contains(entry.url) },
            set: { workspace.setDirectoryExpanded(entry.url, expanded: $0) }
        )
    }
    var body: some View {
        DisclosureGroup(isExpanded: expanded) {
            EditorDirectoryRows(workspace: workspace, directory: entry.url)
        } label: {
            Label(entry.name, systemImage: "folder").lineLimit(1)
                .contextMenu {
                    EditorCreationMenu(workspace: workspace, directory: entry.url)
                    Divider()
                    EditorEntryMenu(workspace: workspace, entry: entry)
                }
        }
    }
}
private struct EditorCreationMenu: View {
    let workspace: EditorWorkspace
    let directory: URL
    var body: some View {
        Button("New File…") { EditorActions.newFile(in: directory, workspace: workspace) }
        Button("New Folder…") { EditorActions.newFolder(in: directory, workspace: workspace) }
    }
}
private struct EditorEntryMenu: View {
    let workspace: EditorWorkspace
    let entry: EditorEntry
    var body: some View {
        Button("Rename…") { EditorActions.rename(entry, workspace: workspace) }
        Button("Delete…", role: .destructive) { EditorActions.delete(entry, workspace: workspace) }
        Divider()
        Button("Copy Name") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(entry.name, forType: .string)
        }
    }
}
private struct EditorFileTab: View {
    @ObservedObject var workspace: EditorWorkspace
    @ObservedObject var document: EditorDocument
    var body: some View {
        HStack(spacing: 6) {
            Button { workspace.selectedID = document.id } label: {
                Text(document.url.lastPathComponent + (document.isDirty ? " •" : "")).lineLimit(1)
            }.buttonStyle(.plain)
            Button { close() } label: { Image(systemName: "xmark").font(.caption) }.buttonStyle(.plain).help("Close file")
        }.padding(8).background(workspace.selectedID == document.id ? Color.accentColor.opacity(0.16) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 5)).help(document.url.path)
            .contextMenu {
                Button("Save") { perform { try workspace.save(document) } }
                Button("Reload from Disk…") { EditorActions.reload(document, workspace: workspace) }
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([document.url]) }
                Button("Close") { close() }
            }
    }
    private func close() {
        perform { _ = try workspace.closeFile(document.id, decision: document.isDirty ? EditorRuntime.askToSave(document) : .discard) }
    }
    private func perform(_ action: () throws -> Void) { do { try action() } catch { workspace.error = error.localizedDescription } }
}
private struct EditorDocumentPane: View {
    @ObservedObject var workspace: EditorWorkspace
    @ObservedObject var document: EditorDocument
    @State private var exportedPDF: URL?
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Save") { perform { try workspace.save(document) } }.keyboardShortcut("s").disabled(!document.isDirty)
                Button("Refresh from Disk", systemImage: "arrow.clockwise") {
                    EditorActions.reload(document, workspace: workspace)
                }.keyboardShortcut("r").help("Reload this document from disk (⌘R)")
                Button("Save All") { perform { try workspace.saveAll() } }.keyboardShortcut("s", modifiers: [.command, .option])
                Button("Find / Replace") {
                    guard let surface = document.surface else { return }
                    surface.window?.makeFirstResponder(surface.textView)
                    let item = NSMenuItem(); item.tag = NSTextFinder.Action.showFindInterface.rawValue
                    surface.textView.performFindPanelAction(item)
                }.keyboardShortcut("f")
                if document.isMarkdown {
                    Button("Convert to PDF", systemImage: "doc.richtext") {
                        perform { exportedPDF = try workspace.convertToPDF(document) }
                    }.help("Export the current text beside this Markdown file. Replaces an existing PDF with the same name.")
                }
                Spacer()
            }.padding(6)
            EditorTextView(workspace: workspace, document: document)
            Divider()
            HStack {
                Text(document.url.path).lineLimit(1).truncationMode(.middle)
                Spacer()
                if let exportedPDF {
                    Text("PDF saved").help(exportedPDF.path)
                }
                Text(position); Text(document.encodingName); Text(document.isDirty ? "Modified" : "Saved")
            }.font(.caption).foregroundStyle(.secondary).padding(5)
        }
        .onChange(of: document.text) { exportedPDF = nil }
        .onChange(of: document.url) { exportedPDF = nil }
    }
    private var position: String {
        let text = document.text as NSString
        let location = min(document.selection.location, text.length)
        let prefix = text.substring(to: location) as NSString
        var index = 0, line = 1
        while index < prefix.length {
            let range = prefix.lineRange(for: NSRange(location: index, length: 0))
            let end = NSMaxRange(range)
            if end > index, ["\n", "\r"].contains(prefix.substring(with: NSRange(location: end - 1, length: 1))) { line += 1 }
            index = end
        }
        let start = text.lineRange(for: NSRange(location: location, length: 0)).location
        return "Ln \(line), Col \(location - start + 1)"
    }
    private func perform(_ action: () throws -> Void) { do { try action() } catch { workspace.error = error.localizedDescription } }
}
@MainActor
private enum EditorActions {
    static func rename(_ entry: EditorEntry, workspace: EditorWorkspace) {
        let alert = NSAlert()
        alert.messageText = "Rename \(entry.name)"
        let name = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        name.stringValue = entry.name
        alert.accessoryView = name
        alert.addButton(withTitle: "Rename"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = name
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try workspace.rename(entry.url, to: name.stringValue) }
        catch { workspace.error = error.localizedDescription }
    }
    static func delete(_ entry: EditorEntry, workspace: EditorWorkspace) {
        do {
            let dirty = try workspace.documents(inside: entry.url).filter(\.isDirty)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Move \(entry.name) to the Trash?"
            alert.informativeText = entry.isDirectory
                ? "This folder and all its contents will be moved to the Trash. Open documents inside it will close."
                : "This item will be moved to the Trash and its open document will close."
            if !dirty.isEmpty {
                alert.informativeText += "\nUnsaved edits in \(dirty.count) open document(s) will be discarded."
            }
            alert.addButton(withTitle: "Move to Trash"); alert.addButton(withTitle: "Cancel")
            // Return should choose the safe option; deleting requires an explicit click.
            alert.buttons[0].keyEquivalent = ""
            alert.buttons[1].keyEquivalent = "\r"
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            try workspace.delete(entry.url, discardChanges: true)
        } catch { workspace.error = error.localizedDescription }
    }
    static func reload(_ document: EditorDocument, workspace: EditorWorkspace) {
        if document.isDirty {
            let alert = NSAlert()
            alert.messageText = "Discard changes and reload \(document.url.lastPathComponent)?"
            alert.informativeText = "Unsaved edits will be replaced with the contents on disk."
            alert.addButton(withTitle: "Reload"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        do { try workspace.reload(document, discardChanges: true) }
        catch { workspace.error = error.localizedDescription }
    }
    static func newFile(in directory: URL, workspace: EditorWorkspace) {
        newItem(in: directory, workspace: workspace, creatingFolder: false)
    }
    static func newFolder(in directory: URL, workspace: EditorWorkspace) {
        newItem(in: directory, workspace: workspace, creatingFolder: true)
    }
    private static func newItem(in directory: URL, workspace: EditorWorkspace, creatingFolder: Bool) {
        let alert = NSAlert(); alert.messageText = creatingFolder ? "New folder" : "New file"; alert.informativeText = directory.path
        let name = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        name.placeholderString = creatingFolder ? "Folder name" : "File name"; alert.accessoryView = name
        alert.addButton(withTitle: "Create"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = name
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            if creatingFolder { try workspace.createFolder(name: name.stringValue, in: directory) }
            else { try workspace.createFile(name: name.stringValue, in: directory) }
        }
        catch { workspace.error = error.localizedDescription }
    }
}
