import AppKit
import SwiftUI

@MainActor
final class EditorTextSurface: NSScrollView, NSTextViewDelegate {
    let textView: CodeTextView
    private weak var document: EditorDocument?
    private var synchronizing = false
    init(document: EditorDocument) {
        self.document = document
        textView = CodeTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        super.init(frame: textView.frame)
        hasVerticalScroller = true; hasHorizontalScroller = false; autohidesScrollers = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true; textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isRichText = false; textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.usesFindBar = true; textView.isIncrementalSearchingEnabled = true
        textView.string = document.text
        textView.delegate = self
        textView.setAccessibilityLabel(document.url.lastPathComponent)
        documentView = textView
        verticalRulerView = LineNumberRuler(textView: textView)
        hasVerticalRuler = true; rulersVisible = true
        textView.onViewportChange = { [weak self] in self?.verticalRulerView?.needsDisplay = true }
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: contentView)
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(storageChanged(_:)), name: NSTextStorage.didProcessEditingNotification, object: textView.textStorage)
        highlight()
    }
    required init?(coder: NSCoder) { fatalError("Use init(document:)") }
    @objc private func scrolled() { verticalRulerView?.needsDisplay = true }
    @objc private func storageChanged(_ notification: Notification) {
        guard !synchronizing, let storage = notification.object as? NSTextStorage,
              storage.editedMask.contains(.editedCharacters) else { return }
        // TextKit undo can edit storage without a text-view delegate callback.
        document?.updateText(storage.string)
        verticalRulerView?.needsDisplay = true
        Task { @MainActor [weak self] in self?.highlight() }
    }
    func reset(text: String) {
        synchronizing = true
        defer { synchronizing = false }
        textView.string = text; textView.undoManager?.removeAllActions()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        document?.selection = NSRange(location: 0, length: 0)
        highlight(); verticalRulerView?.needsDisplay = true
    }
    nonisolated func textDidChange(_ notification: Notification) {
        MainActor.assumeIsolated {
            document?.updateText(textView.string)
            verticalRulerView?.needsDisplay = true
        }
    }
    nonisolated func textViewDidChangeSelection(_ notification: Notification) {
        MainActor.assumeIsolated { document?.selection = textView.selectedRange() }
    }
    private func highlight() {
        guard let storage = textView.textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: full)
        // Deliberately lightweight coloring, not a parser or language server.
        let extensions = ["swift", "c", "h", "cpp", "hpp", "cs", "js", "jsx", "ts", "tsx", "py", "json", "sh", "rb", "java"]
        if storage.length <= 100_000, let ext = document?.url.pathExtension.lowercased(), extensions.contains(ext) {
            let patterns: [(String, NSColor)] = [
                (#"\b(?:class|struct|enum|func|let|var|if|else|for|while|return|import|public|private|static|const|function|def|from|async|await|try|catch|throw|throws|true|false|null|nil|None|True|False|new|using|namespace|void|int|bool)\b"#, .systemPurple),
                (#"\b\d+(?:\.\d+)?\b"#, .systemOrange),
                (#"\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'"#, .systemRed),
                (ext == "py" || ext == "sh" || ext == "rb" ? #"(?m)#.*$"# : #"(?m)//.*$|/\*[\s\S]*?\*/"#, .secondaryLabelColor)
            ]
            for (pattern, color) in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                for match in regex.matches(in: textView.string, range: full) { storage.addAttribute(.foregroundColor, value: color, range: match.range) }
            }
        }
        storage.endEditing()
        textView.typingAttributes = [.font: textView.font!, .foregroundColor: NSColor.textColor]
    }
}

@MainActor
final class CodeTextView: NSTextView {
    // A window's shared undo manager would mix histories from different file tabs.
    private let documentUndoManager = UndoManager()
    override var undoManager: UndoManager? { documentUndoManager }
    var onCloseFile: (() -> Void)?
    var onViewportChange: (() -> Void)?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "w", let onCloseFile {
            onCloseFile(); return true
        }
        return super.performKeyEquivalent(with: event)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { window.makeFirstResponder(self) }
    }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); onViewportChange?() }
    override func insertTab(_ sender: Any?) { insertText("    ", replacementRange: selectedRange()) }
    override func insertNewline(_ sender: Any?) {
        let text = string as NSString
        let position = min(selectedRange().location, text.length)
        let line = text.lineRange(for: NSRange(location: position, length: 0))
        let beforeCursor = text.substring(with: NSRange(location: line.location, length: position - line.location))
        let indent = String(beforeCursor.prefix { $0 == " " || $0 == "\t" })
        let newline = string.contains("\r\n") ? "\r\n" : "\n"
        insertText(newline + indent, replacementRange: selectedRange())
    }
}

@MainActor
private final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?
    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView; ruleThickness = 52
    }
    required init(coder: NSCoder) { fatalError("Use init(textView:)") }
    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSColor.controlBackgroundColor.setFill(); bounds.fill()
        guard let view = textView, let layout = view.layoutManager, let container = view.textContainer else { return }
        let text = view.string as NSString
        layout.ensureLayout(for: container)
        let visible = view.visibleRect
        let glyphs = layout.glyphRange(forBoundingRect: visible.offsetBy(dx: -view.textContainerOrigin.x, dy: -view.textContainerOrigin.y), in: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let style: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]
        var index = 0, number = 1
        while index <= text.length {
            if index > NSMaxRange(characters) { break }
            if index >= characters.location || NSMaxRange(text.lineRange(for: NSRange(location: index, length: 0))) > characters.location {
                let box: NSRect
                if index < text.length {
                    let glyph = layout.glyphIndexForCharacter(at: index)
                    box = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                } else { box = layout.extraLineFragmentRect }
                let point = convert(NSPoint(x: 0, y: box.minY + view.textContainerOrigin.y), from: view)
                let label = "\(number)" as NSString
                label.draw(at: NSPoint(x: ruleThickness - label.size(withAttributes: style).width - 8, y: point.y + 2), withAttributes: style)
            }
            if index == text.length { break }
            index = NSMaxRange(text.lineRange(for: NSRange(location: index, length: 0)))
            number += 1
        }
    }
}

struct EditorTextView: NSViewRepresentable {
    @ObservedObject var workspace: EditorWorkspace
    @ObservedObject var document: EditorDocument
    func makeNSView(context: Context) -> EditorTextSurface {
        let surface = document.surface ?? EditorTextSurface(document: document)
        document.surface = surface
        surface.textView.onCloseFile = { [weak workspace = workspace, weak document = document] in
            guard let workspace, let document else { return }
            do {
                _ = try workspace.closeFile(document.id, decision: document.isDirty ? EditorRuntime.askToSave(document) : .discard)
            } catch { workspace.error = error.localizedDescription }
        }
        return surface
    }
    func updateNSView(_ view: EditorTextSurface, context: Context) {
        if view.textView.string != document.text { view.reset(text: document.text) }
    }
}
