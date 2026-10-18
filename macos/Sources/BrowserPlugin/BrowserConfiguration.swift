import Foundation
import WebKit
import StudioKernel

public struct BrowserConfiguration: Codable, Equatable {
    public var version = 1
    public var initialURL: String
    public init(initialURL: String = "https://www.google.com") { self.initialURL = initialURL }
    public func encoded() throws -> Data { try JSONEncoder().encode(self) }
    public static func decode(_ data: Data) throws -> Self { try JSONDecoder().decode(Self.self, from: data) }
    public func validate() throws {
        guard version == 1 else { throw BrowserError.invalidConfiguration("Unsupported browser configuration version.") }
        _ = try Self.normalizedURL(initialURL)
    }
    public static func normalizedURL(_ address: String) throws -> URL {
        var address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { throw BrowserError.invalidConfiguration("Enter a website address.") }
        if !address.contains(":") { address = "https://" + address }
        guard let url = URL(string: address), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else {
            throw BrowserError.invalidConfiguration("Enter an HTTP or HTTPS website address without embedded credentials.")
        }
        return url
    }
}

open class BrowserPlugin: AppPlugin {
    public init() {}
    open var descriptor: AppDescriptor { AppDescriptor(id: "browser", name: "Browser") }
    open var defaultConfiguration: BrowserConfiguration { BrowserConfiguration() }
    open var suggestedInstanceName: String { "" }
    open func validate(configuration: Data) throws { try BrowserConfiguration.decode(configuration).validate() }
    @MainActor open func configureWebView(_ configuration: WKWebViewConfiguration) {}
    open func restoredURL(_ url: URL) -> URL { url }
}

public enum BrowserError: Error, LocalizedError {
    case invalidConfiguration(String)
    case storage(String)
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message), .storage(let message): return message
        }
    }
}
