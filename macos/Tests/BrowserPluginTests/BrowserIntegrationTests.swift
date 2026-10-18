import AppKit
import BrowserPlugin
import Foundation
import WebKit

/// Opt-in because these tests exercise real WebKit storage and macOS Keychain.
@MainActor
final class BrowserIntegrationTests {
    func testProfileSurvivesProcessRestart() async throws {
        let id = UUID()
        do {
            try await runChild("write", id: id)
            try await runChild("read", id: id)
        } catch {
            try? await runChild("delete", id: id)
            throw error
        }
        try await runChild("delete", id: id)
    }

    private func runChild(_ operation: String, id: UUID) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["--browser-probe", operation, id.uuidString]
        try process.run()
        let deadline = Date().addingTimeInterval(20)
        while process.isRunning && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        if process.isRunning { process.terminate(); throw ProbeError.timeout }
        guard process.terminationStatus == 0 else { throw ProbeError.child(operation, process.terminationStatus) }
    }

    static func probe(operation: String, id: UUID) async throws {
        _ = NSApplication.shared
        let vault = KeychainCookieVault()
        // Instantiate a store to initialize WebKit's main run loop before its removal API.
        _ = WKWebsiteDataStore.default()
        if operation == "delete" {
            try await WKWebsiteDataStore.remove(forIdentifier: id)
            try vault.delete(profileID: id)
            return
        }
        let store = WKWebsiteDataStore(forIdentifier: id)
        try expectTrue(store.isPersistent)
        try expectEqual(store.identifier, id)
        let jar = WebKitCookieJar(store: store.httpCookieStore)
        let persistence = CookiePersistence(profileID: id, jar: jar, vault: vault)
        try await persistence.prepare()
        if operation == "write" {
            let session = HTTPCookie(properties: [.name: "session", .value: "test-session", .domain: "example.test", .path: "/", .secure: "TRUE", HTTPCookiePropertyKey("HttpOnly"): "TRUE"])!
            let persistent = HTTPCookie(properties: [.name: "persistent", .value: "test-persistent", .domain: "example.test", .path: "/", .expires: Date().addingTimeInterval(3600)])!
            await jar.setCookie(session)
            await jar.setCookie(persistent)
            try await persistence.checkpoint()
        } else {
            let cookies = await jar.allCookies()
            try expectEqual(cookies.first { $0.name == "session" }?.value, "test-session")
            try expectEqual(cookies.first { $0.name == "persistent" }?.value, "test-persistent")
            try expectTrue(cookies.first { $0.name == "session" }?.isHTTPOnly == true)
            // A different persistent profile must not inherit either cookie.
            let otherID = UUID()
            let other = WKWebsiteDataStore(forIdentifier: otherID)
            let otherCookies = await WebKitCookieJar(store: other.httpCookieStore).allCookies()
            try expectTrue(otherCookies.isEmpty)
            try await WKWebsiteDataStore.remove(forIdentifier: otherID)
        }
    }
}
private enum ProbeError: Error { case timeout; case child(String, Int32) }
