import Foundation
import WebKit

/// Desktop WebKit omits Safari's version/product tokens by default. Sites such as
/// Teams otherwise classify it as an unknown browser. Report the installed Safari
/// version, not an invented current Chrome/Safari version or a different engine.
public enum TeamsIdentity {
    public static func configure(_ configuration: WKWebViewConfiguration) {
        configuration.applicationNameForUserAgent = currentApplicationName
    }
    public static var currentApplicationName: String? {
        let safari = Bundle(url: URL(fileURLWithPath: "/Applications/Safari.app"))
        return applicationName(safariVersion: safari?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
    }
    public static func applicationName(safariVersion: String?) -> String? {
        guard let version = safariVersion,
              version.range(of: #"^[0-9]+(?:\.[0-9]+){0,3}$"#, options: .regularExpression) != nil else { return nil }
        // Safari's public product token stays 605.1.15, like modern WebKit's UA token.
        return "Version/\(version) Safari/605.1.15"
    }
}
