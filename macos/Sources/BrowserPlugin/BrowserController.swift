import AppKit
import Combine
import Foundation
import StudioKernel
import SwiftUI
import WebKit

@MainActor
public final class BrowserController: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKHTTPCookieStoreObserver {
    public let profileID: UUID
    public let webView: WKWebView
    @Published public var address = ""
    @Published public private(set) var title = "Browser"
    @Published public private(set) var isLoading = false
    @Published public private(set) var canGoBack = false
    @Published public private(set) var canGoForward = false
    @Published public private(set) var isReady = false
    @Published public private(set) var error: String?
    private let plugin: BrowserPlugin
    private let configuration: BrowserConfiguration
    private let persistence: CookiePersistence
    private let navigationStore: BrowserNavigationStore
    private var preparation: Task<Void, Error>?
    private var observations: [NSKeyValueObservation] = []
    private var popups: [BrowserPopup] = []
    private var observingCookies = false

    public init(profileID: UUID, configuration: BrowserConfiguration, navigationStore: BrowserNavigationStore, vault: any CookieVault = KeychainCookieVault(), plugin: BrowserPlugin = BrowserPlugin()) {
        self.plugin = plugin
        self.profileID = profileID
        self.configuration = configuration
        self.navigationStore = navigationStore
        let store = WKWebsiteDataStore(forIdentifier: profileID)
        let webConfiguration = WKWebViewConfiguration()
        webConfiguration.websiteDataStore = store
        plugin.configureWebView(webConfiguration)
        webConfiguration.preferences.javaScriptCanOpenWindowsAutomatically = true
        webView = WKWebView(frame: .zero, configuration: webConfiguration)
        persistence = CookiePersistence(profileID: profileID, jar: WebKitCookieJar(store: store.httpCookieStore), vault: vault)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        observations = [
            webView.observe(\.url, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.address = view.url?.absoluteString ?? "" }
            },
            webView.observe(\.title, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.title = view.title ?? "Browser" }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.isLoading = view.isLoading }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.canGoBack = view.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.canGoForward = view.canGoForward }
            }
        ]
    }

    public func start() {
        guard preparation == nil, !isReady else { return }
        error = nil
        preparation = Task { @MainActor in
            do {
                try await persistence.prepare()
                if !observingCookies {
                    webView.configuration.websiteDataStore.httpCookieStore.add(self)
                    observingCookies = true
                }
                let saved = try navigationStore.load(profileID: profileID)
                let url = try saved.map(plugin.restoredURL) ?? BrowserConfiguration.normalizedURL(configuration.initialURL)
                isReady = true
                address = url.absoluteString
                webView.load(URLRequest(url: url))
            } catch {
                self.error = error.localizedDescription
                throw error
            }
        }
    }

    public func navigate() {
        guard isReady else { return }
        do {
            let url = try BrowserConfiguration.normalizedURL(address)
            error = nil
            webView.load(URLRequest(url: url))
        } catch { self.error = error.localizedDescription }
    }

    public func checkpoint() async throws {
        if let preparation { try await preparation.value }
        try await persistence.checkpoint()
        if let url = webView.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            try navigationStore.save(url, profileID: profileID)
        }
    }

    public func prepareToClose() async throws {
        webView.stopLoading()
        popups.forEach { $0.webView.stopLoading() }
        try await checkpoint()
        if observingCookies {
            webView.configuration.websiteDataStore.httpCookieStore.remove(self)
            observingCookies = false
        }
        popups.forEach { $0.window?.close() }
        popups.removeAll()
    }

    public func retrySessionRestore() {
        guard !isReady else { return }
        preparation = nil
        start()
    }

    nonisolated public func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor [weak self] in
            guard let self, observingCookies else { return }
            do { try await persistence.checkpoint() }
            catch { self.error = error.localizedDescription }
        }
    }

    nonisolated public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        return MainActor.assumeIsolated {
            Task { @MainActor [weak self] in
                guard let self, observingCookies else { return }
                do { try await checkpoint() }
                catch { self.error = error.localizedDescription }
            }

        }
    }
    nonisolated public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        return MainActor.assumeIsolated { showNavigationError(error)
        }
    }
    nonisolated public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        return MainActor.assumeIsolated { showNavigationError(error)
        }
    }
    private func showNavigationError(_ error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        self.error = error.localizedDescription
    }
    nonisolated public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        return MainActor.assumeIsolated {
            error = "The browser content process stopped. Reload this page to continue."

        }
    }

    nonisolated public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        return MainActor.assumeIsolated {
            guard let url = navigationAction.request.url,
            ["http", "https", "about", "blob", "data"].contains(url.scheme?.lowercased() ?? "") else {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)

        }
    }

    nonisolated public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        return MainActor.assumeIsolated {
            guard navigationAction.targetFrame == nil else { return nil }
            // Keep OAuth/login popups in the same profile instead of launching another browser.
            configuration.websiteDataStore = self.webView.configuration.websiteDataStore
            configuration.applicationNameForUserAgent = self.webView.configuration.applicationNameForUserAgent
            let popup = BrowserPopup(configuration: configuration, owner: self)
            popups.append(popup)
            popup.onClose = { [weak self, weak popup] in self?.popups.removeAll { $0 === popup } }
            popup.showWindow(nil)
            return popup.webView

        }
    }
    nonisolated public func webViewDidClose(_ webView: WKWebView) {
        return MainActor.assumeIsolated {
            popups.first { $0.webView === webView }?.window?.close()

        }
    }
    nonisolated public func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        return MainActor.assumeIsolated {
            let alert = NSAlert()
            alert.messageText = frame.request.url?.host ?? "Website"
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
            alert.runModal()
            completionHandler()

        }
    }
    nonisolated public func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        return MainActor.assumeIsolated {
            let alert = NSAlert()
            alert.messageText = frame.request.url?.host ?? "Website"
            alert.informativeText = message
            alert.addButton(withTitle: "OK"); alert.addButton(withTitle: "Cancel")
            completionHandler(alert.runModal() == .alertFirstButtonReturn)

        }
    }
    nonisolated public func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        return MainActor.assumeIsolated {
            let alert = NSAlert()
            alert.messageText = frame.request.url?.host ?? "Website"
            alert.informativeText = prompt
            let field = NSTextField(string: defaultText ?? "")
            field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
            alert.accessoryView = field
            alert.addButton(withTitle: "OK"); alert.addButton(withTitle: "Cancel")
            completionHandler(alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil)

        }
    }
}

@MainActor
private final class BrowserPopup: NSWindowController, NSWindowDelegate {
    let webView: WKWebView
    var onClose: (() -> Void)?
    init(configuration: WKWebViewConfiguration, owner: BrowserController) {
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 680), configuration: configuration)
        let window = NSWindow(contentRect: webView.frame, styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Browser — Sign in or open page"
        window.contentView = webView
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        webView.navigationDelegate = owner
        webView.uiDelegate = owner
    }
    required init?(coder: NSCoder) { fatalError("Use init(configuration:owner:)") }
    func windowWillClose(_ notification: Notification) { onClose?() }
}

public struct BrowserPane: View {
    @ObservedObject private var controller: BrowserController
    public init(controller: BrowserController) { self.controller = controller }
    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { controller.webView.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!controller.canGoBack).help("Back")
                Button { controller.webView.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!controller.canGoForward).help("Forward")
                Button { if controller.isLoading { controller.webView.stopLoading() } else { controller.webView.reload() } } label: {
                    Image(systemName: controller.isLoading ? "xmark" : "arrow.clockwise")
                }.disabled(!controller.isReady).help(controller.isLoading ? "Stop loading" : "Reload")
                TextField("Website address", text: $controller.address).onSubmit(controller.navigate)
                    .disabled(!controller.isReady).accessibilityIdentifier("browserAddress")
                if controller.isLoading { ProgressView().controlSize(.small) }
            }.padding(8)
            if let error = controller.error {
                HStack {
                    Text(error).font(.caption).foregroundStyle(.red)
                    if !controller.isReady { Button("Retry", action: controller.retrySessionRestore) }
                }.padding(8)
            }
            Divider()
            if !controller.isReady && controller.error == nil {
                ProgressView("Restoring browser session…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { BrowserSurface(webView: controller.webView) }
        }
    }
}
private struct BrowserSurface: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
