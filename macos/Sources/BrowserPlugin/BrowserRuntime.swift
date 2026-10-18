import Combine
import Foundation
import StudioKernel
import WebKit

@MainActor
public final class BrowserRuntime: ObservableObject {
    @Published public private(set) var controllers: [UUID: BrowserController] = [:]
    private let navigationStore: BrowserNavigationStore
    private let vault: any CookieVault
    private let plugins: [String: BrowserPlugin]
    public init(directory: URL, vault: any CookieVault = KeychainCookieVault(), plugins: [BrowserPlugin] = [BrowserPlugin()]) {
        navigationStore = BrowserNavigationStore(directory: directory)
        self.vault = vault
        self.plugins = Dictionary(uniqueKeysWithValues: plugins.map { ($0.descriptor.id, $0) })
    }
    public func plugin(for appTypeID: String) -> BrowserPlugin? { plugins[appTypeID] }
    public func open(_ instance: AppInstance) throws {
        guard controllers[instance.id] == nil else { return }
        guard let plugin = plugins[instance.appTypeID] else { throw InstanceError.unknownPlugin }
        let configuration = try BrowserConfiguration.decode(instance.configuration)
        try configuration.validate()
        let controller = BrowserController(profileID: instance.id, configuration: configuration, navigationStore: navigationStore, vault: vault, plugin: plugin)
        controllers[instance.id] = controller
        controller.start()
    }
    public func close(_ id: UUID) async throws {
        guard let controller = controllers[id] else { return }
        try await controller.prepareToClose()
        controllers[id] = nil
    }
    public func checkpointAll() async throws {
        for controller in controllers.values { try await controller.checkpoint() }
    }
    public func prepareToQuit() async throws {
        for controller in controllers.values { controller.webView.stopLoading() }
        try await checkpointAll()
    }
    public func deleteProfile(_ id: UUID) async throws {
        try await close(id)
        // WebKit 14.2 needs its main run loop initialized even for an unopened profile.
        _ = WKWebsiteDataStore.default()
        try await WKWebsiteDataStore.remove(forIdentifier: id)
        try vault.delete(profileID: id)
        try navigationStore.delete(profileID: id)
    }
}
