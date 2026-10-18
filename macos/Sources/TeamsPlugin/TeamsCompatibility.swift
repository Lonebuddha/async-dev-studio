import Foundation

public enum TeamsCompatibility {
    /// Old generic-WebKit sessions may have saved Teams' rejection page. Retry the
    /// app entry point once on restoration; do not redirect live failures in a loop.
    public static func restoredURL(_ url: URL) -> URL {
        guard url.scheme == "https",
              ["teams.microsoft.com", "teams.cloud.microsoft"].contains(url.host?.lowercased() ?? ""),
              ["v2/unsupported-browser", "unsupported-browser"].contains(url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.path = "/v2/"
        components.query = nil
        components.fragment = nil
        return components.url ?? url
    }
}
