import AppKit
@testable import TerminalPlugin

/// Local synthetic reproduction only: no shell, SSH connection, or clipboard access.
@MainActor
enum SelectionResearch {
    static func run() throws {
        _ = NSApplication.shared
        let controller = TerminalController(configuration: TerminalConfiguration())
        let view = controller.view
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = TerminalHostView(terminalView: view)
        window.makeFirstResponder(view)

        func feed(_ text: String) { view.feed(byteArray: Array(text.utf8)[...]) }
        func selectTopLine(clicks: Int = 1) {
            view.selectNone()
            func event(_ type: NSEvent.EventType, x: CGFloat) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: view.bounds.height - 5),
                    modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: clicks, pressure: 1)!
            }
            view.mouseDown(with: event(.leftMouseDown, x: 2))
            if clicks == 1 {
                view.mouseDragged(with: event(.leftMouseDragged, x: 2))
                view.mouseDragged(with: event(.leftMouseDragged, x: 100))
            }
            view.mouseUp(with: event(.leftMouseUp, x: clicks == 1 ? 100 : 2))
        }
        func report(_ label: String, clicks: Int = 1) {
            let expected = view.terminal.getLine(row: 0)?.translateToString(trimRight: true) ?? ""
            selectTopLine(clicks: clicks)
            let actual = view.getSelection()?.trimmingCharacters(in: .whitespacesAndNewlines)
            print("SELECTION RESEARCH: \(label); visible=\(expected.debugDescription); selected=\(String(reflecting: actual))")
        }
        feed("ROW_000")
        report("fresh terminal drag")
        for row in 1...100 { feed(String(format: "\r\nROW_%03d", row)) }
        report("after 100 output lines drag")
        report("after 100 output lines double click", clicks: 2)
        view.scrollUp(lines: 20)
        report("after scrolling up 20 lines drag")
        view.scrollDown(lines: 20)
        selectTopLine()
        print("SELECTION RESEARCH: selection before additional output=\(view.selectionActive)")
        feed("\r")
        print("SELECTION RESEARCH: selection after carriage-return output=\(view.selectionActive)")
        feed("\u{1b}[?1000h")
        report("application enables mouse reporting")
        view.allowMouseReporting = false
        report("mouse reporting disabled locally")
    }
}
