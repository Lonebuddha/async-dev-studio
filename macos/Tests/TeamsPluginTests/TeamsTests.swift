import AppKit
import BrowserPlugin
import Foundation
import StudioKernel
import TeamsPlugin
import WebKit

final class TeamsTests {
    func testSafariIdentityUsesActualVersionAndRejectsInvalidMetadata() throws {
        try expectEqual(TeamsIdentity.applicationName(safariVersion: "17.2.1"), "Version/17.2.1 Safari/605.1.15")
        try expectEqual(TeamsIdentity.applicationName(safariVersion: "26.0"), "Version/26.0 Safari/605.1.15")
        for invalid in [nil, "", "Safari", "17.2 Chrome/999", "17.2\r\nInjected: true", "17.2.1.4.5"] as [String?] {
            try expectNil(TeamsIdentity.applicationName(safariVersion: invalid))
        }
    }

    func testRestoringTeamsRejectionPageRetriesWithoutChangingOtherPages() throws {
        for host in ["teams.microsoft.com", "teams.cloud.microsoft"] {
            let url = URL(string: "https://\(host)/v2/unsupported-browser#isMac=true")!
            try expectEqual(TeamsCompatibility.restoredURL(url).absoluteString, "https://\(host)/v2/")
        }
        for address in ["https://teams.microsoft.com/v2/?board=1", "https://example.com/v2/unsupported-browser", "https://teams.microsoft.com.evil.test/v2/unsupported-browser", "http://teams.microsoft.com/v2/unsupported-browser"] {
            let url = URL(string: address)!
            try expectEqual(TeamsCompatibility.restoredURL(url), url)
        }
    }


    func testTeamsInheritsBrowserValidationAndDefinesOwnDefaults() throws {
        let teams: BrowserPlugin = TeamsPlugin()
        try expectEqual(teams.descriptor.id, "teams")
        try expectEqual(teams.descriptor.name, "Teams")
        try expectEqual(teams.defaultConfiguration.initialURL, "https://teams.microsoft.com/")
        try teams.validate(configuration: teams.defaultConfiguration.encoded())
        try expectThrows(try teams.validate(configuration: BrowserConfiguration(initialURL: "file:///etc/passwd").encoded()))
        try expectEqual(BrowserPlugin().descriptor.id, "browser")
    }
    @MainActor func testGenericBrowserHasNoTeamsPolicy() throws {
        let browser = BrowserPlugin(), teams: BrowserPlugin = TeamsPlugin()
        let rejected = URL(string: "https://teams.microsoft.com/v2/unsupported-browser")!
        try expectEqual(browser.restoredURL(rejected), rejected)
        try expectEqual(teams.restoredURL(rejected).absoluteString, "https://teams.microsoft.com/v2/")
        let plain = WKWebViewConfiguration(), specialized = WKWebViewConfiguration()
        let original = plain.applicationNameForUserAgent
        browser.configureWebView(plain); teams.configureWebView(specialized)
        try expectEqual(plain.applicationNameForUserAgent, original)
        try expectEqual(specialized.applicationNameForUserAgent, TeamsIdentity.currentApplicationName)
    }
    @MainActor func testTeamsAndBrowserDefinitionsPersistIndependently() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = PluginRegistry(); try registry.register(BrowserPlugin()); try registry.register(TeamsPlugin())
        let store = JSONProjectStore(fileURL: directory.appendingPathComponent("workspace.json"))
        let kernel = try ProjectKernel(store: store, plugins: registry)
        let project = try kernel.createProject(name: "Work")
        let browser = try kernel.createInstance(projectID: project.id, appTypeID: "browser", name: "Work", configuration: BrowserConfiguration().encoded())
        let teams = try kernel.createInstance(projectID: project.id, appTypeID: "teams", name: "Work", configuration: TeamsPlugin().defaultConfiguration.encoded())
        try expectNotEqual(browser.id, teams.id)
        try expectEqual(try ProjectKernel(store: store, plugins: registry).projects[0].instances, [browser, teams])
        let runtime = BrowserRuntime(directory: directory, plugins: [BrowserPlugin(), TeamsPlugin()])
        try expectEqual(runtime.plugin(for: "teams")?.descriptor.id, "teams")
        try expectEqual(runtime.plugin(for: "browser")?.descriptor.id, "browser")
        try expectNil(runtime.plugin(for: "terminal"))
    }
    func testTeamsIconIsBundled() throws {
        try expectNotNil(TeamsAssets.iconURL)
        let data = try Data(contentsOf: TeamsAssets.iconURL!)
        let image = NSBitmapImageRep(data: data)
        try expectNotNil(image)
        try expectEqual(image?.pixelsWide, 48)
        try expectEqual(image?.pixelsHigh, 48)
    }

    @MainActor
    func testSafariIdentityIsVisibleToWebKitJavaScript() async throws {
        _ = NSApplication.shared
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        TeamsPlugin().configureWebView(config)
        let view = WKWebView(frame: .zero, configuration: config)
        defer { view.stopLoading() }
        view.loadHTMLString("<html><body>Browser identity test</body></html>", baseURL: nil)
        let deadline = Date().addingTimeInterval(5)
        while view.isLoading, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        let agent = try await view.evaluateJavaScript("navigator.userAgent") as? String
        guard let suffix = TeamsIdentity.currentApplicationName else { try expectTrue(false); return }
        try expectTrue(agent?.contains(suffix) == true)
        try expectTrue(agent?.contains("AppleWebKit/") == true)
        try expectTrue(agent?.contains("Chrome/") == false)
    }

}
