import AppKit
import SwiftUI

/// A folder picker anchored to the configuration sheet containing this button.
/// Never enter a nested runModal loop or guess the parent via NSApp.keyWindow.
public struct DirectoryPickerButton: NSViewRepresentable {
    @Binding private var path: String
    private let onError: (String) -> Void
    public init(path: Binding<String>, onError: @escaping (String) -> Void) {
        _path = path; self.onError = onError
    }
    public func makeCoordinator() -> Coordinator { Coordinator(path: $path, onError: onError) }
    public func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "Choose…", target: context.coordinator, action: #selector(Coordinator.choose(_:)))
        button.bezelStyle = .rounded
        button.setContentHuggingPriority(.required, for: .horizontal)
        context.coordinator.button = button
        return button
    }
    public func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.path = $path
        context.coordinator.onError = onError
        context.coordinator.isEnabled = context.environment.isEnabled
        context.coordinator.updateEnabledState()
    }
    public static func dismantleNSView(_ view: NSButton, coordinator: Coordinator) { coordinator.cancel() }

    @MainActor public final class Coordinator: NSObject {
        var path: Binding<String>
        var onError: (String) -> Void
        var isEnabled = true
        weak var button: NSButton?
        private var activePanel: DirectoryPanel?
        private let makePanel: () -> DirectoryPanel
        convenience init(path: Binding<String>, onError: @escaping (String) -> Void) {
            self.init(path: path, onError: onError, makePanel: { OpenDirectoryPanel() })
        }
        init(path: Binding<String>, onError: @escaping (String) -> Void,
             makePanel: @escaping () -> DirectoryPanel) {
            self.path = path; self.onError = onError; self.makePanel = makePanel
        }
        func updateEnabledState() { button?.isEnabled = isEnabled && activePanel == nil }
        @objc func choose(_ sender: NSButton) {
            guard isEnabled, activePanel == nil else { return }
            guard let window = sender.window else {
                onError("The configuration window is not available. Please reopen the configuration and try again.")
                return
            }
            let panel = makePanel()
            activePanel = panel
            updateEnabledState()
            let expanded = (path.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
            let initial = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded, isDirectory: true) : nil
            panel.begin(on: window, initialDirectory: initial) { [weak self, weak panel] accepted in
                guard let self, let panel, self.activePanel === panel else { return }
                self.activePanel = nil
                self.updateEnabledState()
                guard accepted else { return }
                guard let url = panel.url, url.isFileURL else {
                    self.onError("The selected folder could not be read. Please choose it again.")
                    return
                }
                self.path.wrappedValue = url.path
            }
        }
        func cancel() {
            let panel = activePanel
            // Invalidate before cancellation, since AppKit can complete immediately.
            activePanel = nil
            panel?.cancel()
            updateEnabledState()
        }
    }
}

@MainActor protocol DirectoryPanel: AnyObject {
    var url: URL? { get }
    func begin(on window: NSWindow, initialDirectory: URL?, completion: @escaping (Bool) -> Void)
    func cancel()
}

@MainActor final class OpenDirectoryPanel: DirectoryPanel {
    let panel = NSOpenPanel()
    var url: URL? { panel.url }
    func begin(on window: NSWindow, initialDirectory: URL?, completion: @escaping (Bool) -> Void) {
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = initialDirectory
        panel.beginSheetModal(for: window) { response in completion(response == .OK) }
    }
    func cancel() { panel.cancel(nil) }
}
