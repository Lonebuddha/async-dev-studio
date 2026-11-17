import AppKit
import SwiftTerm
import StudioKernel
import ClaudePlugin
import CodexPlugin
@testable import TerminalPlugin

@MainActor
final class TerminalSelectionTests {
    func testWheelScrollingIsInheritedByAllTerminalPlugins() throws {
        _ = NSApplication.shared
        for plugin: TerminalAppPlugin in [TerminalPlugin(), ClaudePlugin(), CodexPlugin()] {
            let instance = AppInstance(appTypeID: plugin.descriptor.id, name: "Wheel test",
                configuration: try plugin.configurationData(shell: "/bin/sh", workingDirectory: "/tmp", startupCommands: []))
            let controller = try plugin.makeController(for: instance)
            let view = controller.view
            let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.contentView = TerminalHostView(terminalView: view)
            let probe = WheelProbe(); view.terminalDelegate = probe
            func wheel(_ direction: Int32, flags: NSEvent.ModifierFlags = []) {
                let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: direction, wheel2: 0, wheel3: 0)!
                let event = NSEvent(cgEvent: cg)!
                // Recreate the modifier flags through the underlying CG event.
                var cgFlags: CGEventFlags = []
                if flags.contains(.shift) { cgFlags.insert(.maskShift) }
                cg.flags = cgFlags
                view.scrollWheel(with: NSEvent(cgEvent: cg) ?? event)
            }
            lines(1...100, to: view)
            let bottom = view.terminal.buffer.yDisp
            wheel(1)
            try expectTrue(view.terminal.buffer.yDisp < bottom)
            wheel(-1)
            try expectEqual(view.terminal.buffer.yDisp, bottom)
            try expectTrue(probe.output.isEmpty)
            for mode in [1000, 1002, 1003] {
                feed("\u{1b}[?1049h\u{1b}[?\(mode)h\u{1b}[?1006h", to: view)
                probe.output = ""
                wheel(1); try expectTrue(probe.output.contains("\u{1b}[<64;"))
                probe.output = ""
                wheel(-1); try expectTrue(probe.output.contains("\u{1b}[<65;"))
                // Shift-wheel always allows native scrollback, even if the app
                // still has mouse reporting enabled after leaving fullscreen.
                feed("\u{1b}[?1049l", to: view)
                probe.output = ""
                wheel(1, flags: .shift)
                try expectTrue(probe.output.isEmpty)
                try expectTrue(view.terminal.buffer.yDisp < bottom)
                wheel(-1, flags: .shift)
                try expectEqual(view.terminal.buffer.yDisp, bottom)
                view.allowMouseReporting = false
                wheel(1); try expectTrue(probe.output.isEmpty)
                view.scrollDown(lines: 100)
                view.allowMouseReporting = true
                feed("\u{1b}[?\(mode)l", to: view)
            }
        }
    }
    func testHomeAndEndAreInheritedByAllTerminalPlugins() throws {
        _ = NSApplication.shared
        for plugin: TerminalAppPlugin in [TerminalPlugin(), ClaudePlugin(), CodexPlugin()] {
            let instance = AppInstance(appTypeID: plugin.descriptor.id, name: "Line navigation",
                configuration: try plugin.configurationData(shell: "/bin/sh", workingDirectory: "/tmp", startupCommands: []))
            let view = try plugin.makeController(for: instance).view
            let probe = WheelProbe(); view.terminalDelegate = probe
            lines(1...100, to: view)
            let bottom = view.terminal.buffer.yDisp
            for applicationCursor in [false, true] {
                feed(applicationCursor ? "\u{1b}[?1h" : "\u{1b}[?1l", to: view)
                for (keyCode, home) in [(UInt16(115), true), (119, false), (123, true), (124, false)] {
                    probe.output = ""
                    view.selectAll(nil)
                    pressLineBoundary(home: home, keyCode: keyCode, in: view)
                    try expectEqual(probe.output, home ? "\u{01}" : "\u{05}")
                    try expectFalse(view.selectionActive)
                    try expectEqual(view.terminal.buffer.yDisp, bottom)
                }
                feed("\u{1b}[?1049h", to: view)
                for home in [true, false] {
                    probe.output = ""
                    pressLineBoundary(home: home, keyCode: home ? 115 : 119, in: view)
                    let prefix = applicationCursor ? "\u{1b}O" : "\u{1b}["
                    try expectEqual(probe.output, prefix + (home ? "H" : "F"))
                }
                feed("\u{1b}[?1049l", to: view)
            }
        }
    }

    func testHomeAndEndEditRealShellCommandLines() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // Isolate shell initialization and history from the user's real configuration.
        try Data().write(to: folder.appendingPathComponent("inputrc"))
        let environment = ["HOME": folder.path, "ZDOTDIR": folder.path, "INPUTRC": folder.appendingPathComponent("inputrc").path,
                           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        for (shell, setup) in [("/bin/zsh", "bindkey -e"), ("/bin/bash", "set -o emacs")] {
            let marker = folder.appendingPathComponent("ready")
            try? FileManager.default.removeItem(at: marker)
            let session = TerminalSession(configuration: TerminalConfiguration(shell: shell, workingDirectory: folder.path,
                startupCommands: [setup, "printf ready > ready"]), environment: environment)
            let view = StudioTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
            let probe = WheelProbe(); view.terminalDelegate = probe
            probe.onSend = { session.send(Data($0)) }
            session.onOutput = { [weak view] data in view?.feed(byteArray: Array(data)[...]) }
            defer { session.stop() }
            try session.start()
            try await waitForShell { FileManager.default.fileExists(atPath: marker.path) }
            // Home must put the opening quote before the text; End must append
            // the closing quote. Wrong cursor movement produces a different file.
            view.insertText("middle", replacementRange: NSRange(location: NSNotFound, length: 0))
            pressLineBoundary(home: true, keyCode: 115, in: view)
            view.insertText("printf '%s' 'START ", replacementRange: NSRange(location: NSNotFound, length: 0))
            pressLineBoundary(home: false, keyCode: 119, in: view)
            view.insertText(" END' > result; exit\n", replacementRange: NSRange(location: NSNotFound, length: 0))
            try await waitForShell { session.processID == nil }
            try expectEqual(session.state, .exited(0))
            let result = folder.appendingPathComponent("result")
            try expectEqual(try String(contentsOf: result, encoding: .utf8), "START middle END")
            try FileManager.default.removeItem(at: result)
        }
    }

    private func pressLineBoundary(home: Bool, keyCode: UInt16, in view: TerminalView) {
        let character = String(UnicodeScalar(home ? NSHomeFunctionKey : NSEndFunctionKey)!)
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.function, .numericPad],
            timestamp: 0, windowNumber: 0, context: nil, characters: character, charactersIgnoringModifiers: character,
            isARepeat: false, keyCode: keyCode)!
        view.keyDown(with: event)
    }

    private func waitForShell(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            guard Date() < deadline else { throw NSError(domain: "TerminalLineNavigationTimeout", code: 1) }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func testCyrillicTextInputAcrossTerminalPlugins() throws {
        _ = NSApplication.shared
        for plugin: TerminalAppPlugin in [TerminalPlugin(), ClaudePlugin(), CodexPlugin()] {
            let instance = AppInstance(appTypeID: plugin.descriptor.id, name: "Russian input",
                configuration: try plugin.configurationData(shell: "/bin/sh", workingDirectory: "/tmp", startupCommands: []))
            let controller = try plugin.makeController(for: instance)
            let probe = WheelProbe(); controller.view.terminalDelegate = probe
            let text = "Привет, мир! Ёжик — русский текст."
            controller.view.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            try expectEqual(probe.output, text)
            controller.view.insertText(NSAttributedString(string: text), replacementRange: NSRange(location: NSNotFound, length: 0))
            try expectEqual(probe.output, text + text)
            let bytes = Array(text.utf8)
            // PTY reads may split inside a Cyrillic code point.
            for byte in bytes { controller.view.feed(byteArray: [byte][...]) }
            try expectTrue(controller.view.terminal.getLine(row: 0)!.translateToString(trimRight: true).contains(text))
        }
    }
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

private final class WheelProbe: TerminalViewDelegate {
    var output = ""
    var onSend: ((ArraySlice<UInt8>) -> Void)?
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        output += String(decoding: data, as: UTF8.self)
        onSend?(data)
    }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
}
