import BrowserPlugin
import Foundation
import StudioKernel
import WebKit

public final class TeamsPlugin: BrowserPlugin {
    public override init() { super.init() }
    public override var descriptor: AppDescriptor { AppDescriptor(id: "teams", name: "Teams") }
    public override var defaultConfiguration: BrowserConfiguration { BrowserConfiguration(initialURL: "https://teams.microsoft.com/") }
    public override var suggestedInstanceName: String { "Teams" }
    @MainActor public override func configureWebView(_ configuration: WKWebViewConfiguration) { TeamsIdentity.configure(configuration) }
    public override func restoredURL(_ url: URL) -> URL { TeamsCompatibility.restoredURL(url) }
}
