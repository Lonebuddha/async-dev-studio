import Foundation
import StudioKernel
import BrowserPlugin

final class BrowserTests {
    func testBrowserConfigurationRejectsUnsafeURLs() throws {
        for address in ["", "file:///etc/passwd", "javascript:alert(1)", "https://", "ftp://example.com"] {
            try expectThrows(try BrowserConfiguration(initialURL: address).validate())
        }
        try BrowserConfiguration(initialURL: "https://example.com/path?q=value").validate()
        try expectEqual(try BrowserConfiguration.normalizedURL("example.com").absoluteString, "https://example.com")
    }

    func testBrowserInstancesPersistWithStableProfileIDs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JSONProjectStore(fileURL: directory.appendingPathComponent("workspace.json"))
        let registry = PluginRegistry()
        try registry.register(BrowserPlugin())
        let kernel = try ProjectKernel(store: store, plugins: registry)
        let project = try kernel.createProject(name: "Project")
        let config = try BrowserConfiguration(initialURL: "https://example.com").encoded()
        let first = try kernel.createInstance(projectID: project.id, appTypeID: "browser", name: "JIRA", configuration: config)
        let second = try kernel.createInstance(projectID: project.id, appTypeID: "browser", name: "Other account", configuration: config)
        try expectNotEqual(first.id, second.id)
        let restored = try ProjectKernel(store: store, plugins: registry)
        try expectEqual(restored.projects[0].instances, [first, second])
        try kernel.updateInstance(id: first.id, name: "Renamed", configuration: config)
        try expectEqual(kernel.projects[0].instances[0].id, first.id)
    }

    func testCookieSnapshotPreservesSessionAndSecurityAttributes() throws {
        let cookie = HTTPCookie(properties: [
            .name: "session", .value: "test-token", .domain: "example.test", .path: "/",
            .secure: "TRUE", HTTPCookiePropertyKey("HttpOnly"): "TRUE",
            HTTPCookiePropertyKey("SameSite"): "Lax"
        ])!
        let snapshot = try CookieSnapshot.capture([cookie])
        let restored = try snapshot.cookies()
        try expectEqual(restored.count, 1)
        try expectEqual(restored[0].value, "test-token")
        try expectTrue(restored[0].isSessionOnly)
        try expectTrue(restored[0].isSecure)
        try expectTrue(restored[0].isHTTPOnly)
    }

    func testExpiredCookiesAreNotResurrectedAndPersistentExpiryIsPreserved() throws {
        let session = HTTPCookie(properties: [.name: "session", .value: "s", .domain: "example.test", .path: "/"])!
        let persistent = HTTPCookie(properties: [.name: "persistent", .value: "p", .domain: "example.test", .path: "/", .expires: Date().addingTimeInterval(3600)])!
        let expired = HTTPCookie(properties: [.name: "old", .value: "o", .domain: "example.test", .path: "/", .expires: Date().addingTimeInterval(-3600)])!
        let restored = try CookieSnapshot.capture([session, persistent, expired]).cookies()
        try expectEqual(restored.map(\.name), ["session", "persistent"])
        try expectFalse(restored[1].isSessionOnly)
        try expectEqual(restored[1].expiresDate, persistent.expiresDate)
    }

    @MainActor func testRestoresCookiesBeforeLoadingAndLogoutClearsSnapshot() async throws {
        let vault = MemoryCookieVault()
        let id = UUID()
        let cookie = HTTPCookie(properties: [.name: "session", .value: "test-token", .domain: "example.test", .path: "/"])!
        try vault.save(try CookieSnapshot.capture([cookie]).data, profileID: id)
        let jar = MemoryCookieJar()
        let persistence = CookiePersistence(profileID: id, jar: jar, vault: vault)
        try await persistence.prepare()
        try expectEqual(jar.values.first?.value, "test-token")
        jar.values = [] // Website logout deletes the session cookie.
        try await persistence.checkpoint()
        let newJar = MemoryCookieJar()
        let restarted = CookiePersistence(profileID: id, jar: newJar, vault: vault)
        try await restarted.prepare()
        try expectTrue(newJar.values.isEmpty)
    }

    @MainActor func testProfileSnapshotsAreIsolatedAndPreparationIsIdempotent() async throws {
        let vault = MemoryCookieVault()
        let first = UUID(), second = UUID()
        let cookie = HTTPCookie(properties: [.name: "session", .value: "first-account", .domain: "example.test", .path: "/"])!
        let firstJar = MemoryCookieJar()
        firstJar.values = [cookie]
        let firstSession = CookiePersistence(profileID: first, jar: firstJar, vault: vault)
        try await firstSession.prepare()
        try await firstSession.checkpoint()
        let secondJar = MemoryCookieJar()
        let secondSession = CookiePersistence(profileID: second, jar: secondJar, vault: vault)
        try await secondSession.prepare()
        try expectTrue(secondJar.values.isEmpty)
        let restoredJar = MemoryCookieJar()
        let restored = CookiePersistence(profileID: first, jar: restoredJar, vault: vault)
        try await restored.prepare()
        restoredJar.values = []
        try await restored.prepare()
        try expectTrue(restoredJar.values.isEmpty) // Re-selection must not restore a logged-out cookie.
    }

    @MainActor func testStorageFailureIsReportedAndNotSilentlyIgnored() async throws {
        let vault = MemoryCookieVault()
        let session = CookiePersistence(profileID: UUID(), jar: MemoryCookieJar(), vault: vault)
        try await session.prepare()
        vault.failSave = true
        do { try await session.checkpoint(); try expectTrue(false) }
        catch is BrowserTestFailure {}
    }

    @MainActor func testCloseCheckpointWaitsForConcurrentLogout() async throws {
        let vault = MemoryCookieVault(), id = UUID()
        let jar = DelayedCookieJar()
        jar.values = [HTTPCookie(properties: [.name: "session", .value: "test-token", .domain: "example.test", .path: "/"])!]
        let persistence = CookiePersistence(profileID: id, jar: jar, vault: vault)
        try await persistence.prepare()
        let older = Task { try await persistence.checkpoint() }
        while jar.pending == nil { await Task.yield() }
        jar.values = []
        let closing = Task { try await persistence.checkpoint() }
        await Task.yield()
        jar.resume()
        try await closing.value
        try await older.value
        let saved = try CookieSnapshot(data: vault.load(profileID: id)!).cookies()
        try expectTrue(saved.isEmpty)
        try expectEqual(jar.reads, 2)
    }

    func testLastURLRestoresPerInstanceAndRejectsUnsafeSavedURL() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BrowserNavigationStore(directory: directory)
        let first = UUID(), second = UUID()
        try store.save(URL(string: "https://example.com/board")!, profileID: first)
        try expectEqual(try BrowserNavigationStore(directory: directory).load(profileID: first)?.absoluteString, "https://example.com/board")
        try expectNil(try store.load(profileID: second))
        try expectThrows(try store.save(URL(string: "file:///tmp/private")!, profileID: first))
    }
}

private enum BrowserTestFailure: Error { case storage }
private final class MemoryCookieVault: CookieVault {
    var data: [UUID: Data] = [:]
    var failSave = false
    func load(profileID: UUID) throws -> Data? { data[profileID] }
    func save(_ value: Data, profileID: UUID) throws {
        if failSave { throw BrowserTestFailure.storage }
        data[profileID] = value
    }
    func delete(profileID: UUID) throws { data[profileID] = nil }
}
@MainActor
private final class MemoryCookieJar: CookieJar {
    var values: [HTTPCookie] = []
    func allCookies() async -> [HTTPCookie] { values }
    func setCookie(_ cookie: HTTPCookie) async { values.append(cookie) }
}

@MainActor
private final class DelayedCookieJar: CookieJar {
    var values: [HTTPCookie] = []
    var reads = 0
    var pending: CheckedContinuation<[HTTPCookie], Never>?
    private var captured: [HTTPCookie] = []
    func allCookies() async -> [HTTPCookie] {
        reads += 1
        if reads > 1 { return values }
        captured = values
        return await withCheckedContinuation { pending = $0 }
    }
    func resume() { pending?.resume(returning: captured); pending = nil }
    func setCookie(_ cookie: HTTPCookie) async { values.append(cookie) }
}
