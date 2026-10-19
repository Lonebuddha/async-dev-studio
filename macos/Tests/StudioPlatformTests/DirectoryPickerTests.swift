import AppKit
import SwiftUI
@testable import StudioPlatform

@MainActor
final class DirectoryPickerTests {
    func testAsynchronousSheetOwnershipSelectionAndDuplicateClicks() throws {
        _ = NSApplication.shared
        let unrelated = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        let configuration = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        unrelated.isReleasedWhenClosed = false; configuration.isReleasedWhenClosed = false
        defer { unrelated.close(); configuration.close() }
        let button = NSButton(); configuration.contentView!.addSubview(button)
        var path = "/initial/folder", errors: [String] = [], creations = 0
        let panel = FakeDirectoryPanel()
        let coordinator = DirectoryPickerButton.Coordinator(path: Binding(get: { path }, set: { path = $0 }), onError: { errors.append($0) }, makePanel: { creations += 1; return panel })
        coordinator.button = button
        coordinator.choose(button)
        // Presentation returns before completion; the configuration's actual
        // window is used even if another app window could be the key window.
        try expectTrue(panel.parent === configuration)
        try expectEqual(panel.initialDirectory?.path, "/initial/folder")
        try expectEqual(path, "/initial/folder")
        try expectFalse(button.isEnabled)
        coordinator.choose(button); try expectEqual(creations, 1)
        panel.url = URL(fileURLWithPath: "/chosen/folder", isDirectory: true)
        panel.complete(true)
        try expectEqual(path, "/chosen/folder"); try expectTrue(button.isEnabled); try expectTrue(errors.isEmpty)
        panel.complete(true); try expectEqual(path, "/chosen/folder")
    }
    func testCancellationAndStaleCompletionNeverChangeConfiguration() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let button = NSButton(); window.contentView!.addSubview(button)
        var path = "/original", errors: [String] = []
        let first = FakeDirectoryPanel(), second = FakeDirectoryPanel()
        var panels = [first, second]
        let coordinator = DirectoryPickerButton.Coordinator(path: Binding(get: { path }, set: { path = $0 }), onError: { errors.append($0) }, makePanel: { panels.removeFirst() })
        coordinator.button = button
        coordinator.choose(button)
        coordinator.cancel()
        try expectEqual(first.cancellations, 1); try expectTrue(button.isEnabled)
        coordinator.choose(button)
        first.url = URL(fileURLWithPath: "/stale"); first.complete(true)
        try expectEqual(path, "/original"); try expectFalse(button.isEnabled)
        second.complete(false)
        try expectEqual(path, "/original"); try expectTrue(button.isEnabled); try expectTrue(errors.isEmpty)
        coordinator.cancel(); try expectEqual(second.cancellations, 0)
    }
    func testMissingWindowInvalidSelectionAndDisabledControls() throws {
        _ = NSApplication.shared
        var path = "/original", errors: [String] = [], creations = 0
        let panel = FakeDirectoryPanel(), button = NSButton()
        let coordinator = DirectoryPickerButton.Coordinator(path: Binding(get: { path }, set: { path = $0 }), onError: { errors.append($0) }, makePanel: { creations += 1; return panel })
        coordinator.button = button
        coordinator.choose(button)
        try expectEqual(creations, 0); try expectEqual(errors.count, 1)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false; defer { window.close() }
        window.contentView!.addSubview(button)
        coordinator.isEnabled = false; coordinator.choose(button); try expectEqual(creations, 0)
        coordinator.isEnabled = true; coordinator.choose(button)
        panel.url = URL(string: "https://example.com/folder")
        coordinator.isEnabled = false
        panel.complete(true)
        try expectEqual(path, "/original"); try expectEqual(errors.count, 2); try expectFalse(button.isEnabled)
    }
}

@MainActor private final class FakeDirectoryPanel: DirectoryPanel {
    var url: URL?
    var parent: NSWindow?
    var initialDirectory: URL?
    var cancellations = 0
    private var completion: ((Bool) -> Void)?
    func begin(on window: NSWindow, initialDirectory: URL?, completion: @escaping (Bool) -> Void) {
        parent = window; self.initialDirectory = initialDirectory; self.completion = completion
    }
    func cancel() { cancellations += 1 }
    func complete(_ accepted: Bool) { completion?(accepted) }
}
