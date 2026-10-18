import AppKit
import Combine
import Foundation
import StudioKernel
import SwiftTerm
import SwiftUI

/// Owns both session and emulator so switching SwiftUI tabs cannot lose scrollback.
@MainActor
public final class TerminalController: NSObject, ObservableObject, TerminalViewDelegate {
    public let session: TerminalSession
    public let view: TerminalView
    private var subscription: AnyCancellable?
    private var prepareForStart: (() throws -> TerminalConfiguration)?
    @Published public private(set) var startupError: String?

    public init(configuration: TerminalConfiguration, prepareForStart: (() throws -> TerminalConfiguration)? = nil) {
        self.prepareForStart = prepareForStart
        session = TerminalSession(configuration: configuration)
        view = StudioTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        super.init()
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.configureNativeColors()
        view.terminalDelegate = self
        session.onOutput = { [weak view] data in view?.feed(byteArray: Array(data)[...]) }
        subscription = session.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }

    public func start() {
        guard session.processID == nil else { return }
        startupError = nil
        try? session.resize(columns: view.terminal.cols, rows: view.terminal.rows)
        do {
            if let prepareForStart { try session.configureForNextStart(prepareForStart()) }
            try session.start()
        } catch { startupError = error.localizedDescription }
    }

    public func configureForNextStart(_ configuration: TerminalConfiguration, preparation: (() throws -> TerminalConfiguration)? = nil) throws {
        try session.configureForNextStart(configuration)
        prepareForStart = preparation
    }

    nonisolated public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        MainActor.assumeIsolated { try? session.resize(columns: newCols, rows: newRows) }
    }
    nonisolated public func send(source: TerminalView, data: ArraySlice<UInt8>) {
        MainActor.assumeIsolated { session.send(Data(data)) }
    }
    nonisolated public func setTerminalTitle(source: TerminalView, title: String) {}
    nonisolated public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated public func scrolled(source: TerminalView, position: Double) {}
    nonisolated public func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    nonisolated public func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    nonisolated public func bell(source: TerminalView) { MainActor.assumeIsolated { NSSound.beep() } }
    nonisolated public func clipboardCopy(source: TerminalView, content: Data) {
        // Clipboard writes requested by terminal escape sequences are not enabled.
        // User-initiated copy/paste remains provided by TerminalView.
    }
    nonisolated public func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        MainActor.assumeIsolated { _ = NSWorkspace.shared.open(url) }
    }
}

/// Handle Copy before SwiftTerm's keyDown clears the selected text. SwiftUI's
/// menu routing does not always consume AppKit terminal keyboard equivalents.
final class StudioTerminalView: TerminalView {
    private func isCopyShortcut(_ event: NSEvent) -> Bool {
        event.modifierFlags.contains(.command)
            && event.modifierFlags.intersection([.control, .option, .shift]).isEmpty
            && event.charactersIgnoringModifiers?.lowercased() == "c"
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, isCopyShortcut(event) {
            copy(self)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func copy(_ sender: Any) {
        let item = NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        guard validateUserInterfaceItem(item) else { return }
        super.copy(sender)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        for (title, action) in [("Copy", #selector(copy(_:))), ("Paste", #selector(paste(_:))), ("Select All", #selector(selectAll(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            if title == "Copy" { item.toolTip = "Hold Shift while dragging to select text when a terminal program uses the mouse." }
            menu.addItem(item)
        }
        return menu
    }
}

/// Compiled-in runtime factory; distinct IDs always own distinct controllers.
@MainActor
public final class TerminalRuntime: ObservableObject {
    @Published public private(set) var controllers: [UUID: TerminalController] = [:]
    private var retiring: [TerminalController] = []
    private let plugins: [String: TerminalAppPlugin]
    public init(plugins: [TerminalAppPlugin] = [TerminalPlugin()]) {
        self.plugins = Dictionary(uniqueKeysWithValues: plugins.map { ($0.descriptor.id, $0) })
    }
    public func plugin(for type: String) -> TerminalAppPlugin? { plugins[type] }
    public var hasRunningSessions: Bool { (Array(controllers.values) + retiring).contains { $0.session.processID != nil } }

    public func open(_ instance: AppInstance) throws {
        guard let plugin = plugins[instance.appTypeID], controllers[instance.id] == nil else { return }
        let controller = try plugin.makeController(for: instance)
        controllers[instance.id] = controller
        controller.start()
    }
    public func configure(_ id: UUID, configuration: TerminalConfiguration) throws {
        try controllers[id]?.configureForNextStart(configuration)
    }
    public func configure(_ instance: AppInstance) throws {
        guard let controller = controllers[instance.id], let plugin = plugins[instance.appTypeID] else { return }
        try plugin.configure(controller, instance: instance)
    }
    public func close(_ id: UUID) {
        guard let controller = controllers[id] else { return }
        controller.session.stop()
        retiring.append(controller)
        controllers[id] = nil
        Task { @MainActor [weak self, controller] in
            while controller.session.processID != nil {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            self?.retiring.removeAll { $0 === controller }
        }
    }
    public func stopAll() { (Array(controllers.values) + retiring).forEach { $0.session.stop() } }
}

public struct TerminalPane: View {
    @ObservedObject private var controller: TerminalController
    public init(controller: TerminalController) { self.controller = controller }
    public var body: some View {
        VStack(spacing: 0) {
            if controller.session.state != .running {
                HStack {
                    Text(status)
                    Spacer()
                    Button("Start", action: controller.start)
                        .disabled(controller.session.processID != nil)
                }
                .padding(10)
                Divider()
            }
            TerminalSurface(controller: controller)
        }
    }
    private var status: String {
        if let error = controller.startupError { return error }
        switch controller.session.state {
        case .stopped: return "Terminal stopped"
        case .running: return "Running"
        case .exited(let code): return "Shell exited with status \(code)"
        case .failed(let message): return message
        }
    }
}

/// SwiftUI can collapse a representable while detaching or attaching a tab.
/// Keep those transient frames out of the emulator and PTY: resizing a terminal
/// down to its minimum grid can discard screen contents and redraw shell apps.
final class TerminalHostView: NSView {
    let terminalView: TerminalView

    init(terminalView: TerminalView) {
        self.terminalView = terminalView
        super.init(frame: terminalView.frame)
        terminalView.autoresizingMask = []
        addSubview(terminalView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        // Wait for a usable layout rather than shrinking the terminal to a
        // one-cell grid during SwiftUI's tab replacement.
        guard bounds.width >= terminalView.font.pointSize * 2,
              bounds.height >= terminalView.font.pointSize * 2 else { return }
        if terminalView.frame != bounds { terminalView.frame = bounds }
    }
}

private struct TerminalSurface: NSViewRepresentable {
    let controller: TerminalController
    func makeNSView(context: Context) -> TerminalHostView { TerminalHostView(terminalView: controller.view) }
    func updateNSView(_ host: TerminalHostView, context: Context) {
        let view = host.terminalView
        DispatchQueue.main.async { [weak view] in
            guard let view, let window = view.window, window.attachedSheet == nil, window.isKeyWindow else { return }
            if window.firstResponder !== view { window.makeFirstResponder(view) }
        }
    }
}
