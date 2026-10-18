import AppKit
import SwiftTerm
@testable import TerminalPlugin

@MainActor
final class TerminalSelectionTests {
    func testClickRestoresKeyboardFocus() throws {
        try fixture { view, window in
            let other = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
            window.contentView!.addSubview(other)
            try expectTrue(window.makeFirstResponder(other))
            try expectTrue(window.firstResponder === other)
            let click = NSEvent.mouseEvent(with: .leftMouseDown,
                location: NSPoint(x: 30, y: view.bounds.height - 30), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            view.mouseDown(with: click)
            try expectTrue(window.firstResponder === view)
        }
    }
    private func fixture(_ body: (TerminalView, NSWindow) throws -> Void) throws {
        _ = NSApplication.shared
        let controller = TerminalController(configuration: TerminalConfiguration())
        let view = controller.view
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = TerminalHostView(terminalView: view)
        window.makeFirstResponder(view)
        try body(view, window)
    }

    private func feed(_ text: String, to view: TerminalView) { view.feed(byteArray: Array(text.utf8)[...]) }
    private func lines(_ range: ClosedRange<Int>, to view: TerminalView) {
        for row in range { feed(String(format: "\r\nROW_%04d", row), to: view) }
    }
    private func select(_ view: TerminalView, window: NSWindow, reverse: Bool = false, clicks: Int = 1, flags: NSEvent.ModifierFlags = []) {
        view.selectNone()
        let cell = view.getOptimalFrameSize().height / CGFloat(view.terminal.rows)
        func mouse(_ type: NSEvent.EventType, x: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: view.bounds.height - cell / 2),
                modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: clicks, pressure: 1)!
        }
        let start: CGFloat = reverse ? 100 : 1
        let end: CGFloat = reverse ? 1 : 100
        view.mouseDown(with: mouse(.leftMouseDown, x: start))
        if clicks == 1 { view.mouseDragged(with: mouse(.leftMouseDragged, x: end)) }
        view.mouseUp(with: mouse(.leftMouseUp, x: end))
    }
    private func selected(_ view: TerminalView) -> String? { view.getSelection()?.trimmingCharacters(in: .whitespacesAndNewlines) }

    func testSelectionAfterScrollbackAndRollover() throws {
        try fixture { view, window in
            feed("ROW_0000", to: view)
            for end in [100, 800] {
                lines((end == 100 ? 1 : 101)...end, to: view)
                for scroll in [0, 20] {
                    if scroll > 0 { view.scrollUp(lines: scroll) }
                    let expected = view.terminal.getLine(row: 0)!.translateToString(trimRight: true)
                    for reverse in [false, true] {
                        select(view, window: window, reverse: reverse)
                        try expectEqual(selected(view), expected)
                    }
                    select(view, window: window, clicks: 2)
                    try expectEqual(selected(view), expected)
                    if scroll > 0 { view.scrollDown(lines: scroll) }
                }
            }
        }
    }

    func testOutputPreservesSelectionUntilOverwrittenOrEvicted() throws {
        try fixture { view, window in
            feed("ROW_0000", to: view)
            select(view, window: window)
            feed("\r", to: view)
            try expectEqual(selected(view), "ROW_0000")
            lines(1...100, to: view)
            try expectEqual(selected(view), "ROW_0000")
            select(view, window: window)
            let expected = selected(view)
            lines(101...550, to: view)
            try expectEqual(selected(view), expected)
            lines(551...1200, to: view)
            try expectFalse(view.selectionActive)
            select(view, window: window)
            feed("\u{1b}[HCHANGED\u{1b}[K", to: view)
            try expectFalse(view.selectionActive)
            select(view, window: window)
            feed("\u{1b}[?1049h", to: view)
            try expectFalse(view.selectionActive)
        }
    }

    func testShiftSelectionOverridesMouseReporting() throws {
        try fixture { view, window in
            feed("ROW_0000", to: view)
            lines(1...100, to: view)
            let expected = view.terminal.getLine(row: 0)!.translateToString(trimRight: true)
            for mode in [1000, 1002, 1003] {
                feed("\u{1b}[?\(mode)h", to: view)
                select(view, window: window)
                try expectFalse(view.selectionActive)
                select(view, window: window, flags: .shift)
                try expectEqual(selected(view), expected)
                try expectTrue(view.allowMouseReporting)
                feed("\u{1b}[?\(mode)l", to: view)
            }
        }
    }
}
