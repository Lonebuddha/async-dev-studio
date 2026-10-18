import Foundation
import Security
import WebKit

public protocol CookieVault {
    func load(profileID: UUID) throws -> Data?
    func save(_ data: Data, profileID: UUID) throws
    func delete(profileID: UUID) throws
}

/// Session credentials belong in Keychain, never the workspace or a plaintext cookie file.
public struct KeychainCookieVault: CookieVault {
    private let service = "dev.asyncstudio.browser.session-cookies"
    public init() {}
    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString,
         kSecAttrSynchronizable as String: false]
    }
    public func load(profileID: UUID) throws -> Data? {
        var query = query(profileID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data else { throw BrowserError.storage("Couldn’t read saved browser credentials.") }
        return data
    }
    public func save(_ data: Data, profileID: UUID) throws {
        let query = query(profileID)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            try check(SecItemAdd(item as CFDictionary, nil))
        } else { try check(status) }
    }
    public func delete(profileID: UUID) throws {
        let status = SecItemDelete(query(profileID) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }
    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
            throw BrowserError.storage("Couldn’t save or restore browser login state: \(message)")
        }
    }
}

/// Snapshots cookies without changing their expiry or session/security attributes.
/// This also covers WebKit disk-flush latency when quitting immediately after login.
public struct CookieSnapshot {
    public let data: Data
    public init(data: Data) { self.data = data }
    public static func capture(_ cookies: [HTTPCookie]) throws -> Self {
        let records: [[String: Any]] = cookies.filter { $0.expiresDate.map { $0 > Date() } ?? true }.map { cookie in
            var fields: [String: Any] = [:]
            for (key, value) in cookie.properties ?? [:] {
                if let url = value as? URL { fields[key.rawValue] = url.absoluteString }
                else if value is String || value is Date || value is NSNumber || value is [String] { fields[key.rawValue] = value }
            }
            return fields
        }
        return Self(data: try PropertyListSerialization.data(fromPropertyList: ["version": 1, "cookies": records], format: .binary, options: 0))
    }
    public func cookies() throws -> [HTTPCookie] {
        guard let document = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              document["version"] as? Int == 1,
              let records = document["cookies"] as? [[String: Any]] else {
            throw BrowserError.storage("The saved browser session has an unsupported format.")
        }
        return try records.compactMap { record in
            let fields = Dictionary(uniqueKeysWithValues: record.map { (HTTPCookiePropertyKey($0.key), $0.value) })
            guard let cookie = HTTPCookie(properties: fields) else { throw BrowserError.storage("A saved browser cookie could not be restored.") }
            guard cookie.expiresDate.map({ $0 > Date() }) ?? true else { return nil }
            return cookie
        }
    }
}

@MainActor
public protocol CookieJar: AnyObject {
    func allCookies() async -> [HTTPCookie]
    func setCookie(_ cookie: HTTPCookie) async
}

@MainActor
public final class WebKitCookieJar: CookieJar {
    public let store: WKHTTPCookieStore
    public init(store: WKHTTPCookieStore) { self.store = store }
    public func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in store.getAllCookies { continuation.resume(returning: $0) } }
    }
    public func setCookie(_ cookie: HTTPCookie) async {
        await withCheckedContinuation { continuation in store.setCookie(cookie) { continuation.resume() } }
    }
}

@MainActor
public final class CookiePersistence {
    public let profileID: UUID
    private let jar: any CookieJar
    private let vault: any CookieVault
    private var prepared = false
    private var preparation: Task<Void, Error>?
    private var checkpointTask: Task<Void, Error>?
    private var needsCheckpoint = false

    public init(profileID: UUID, jar: any CookieJar, vault: any CookieVault) {
        self.profileID = profileID; self.jar = jar; self.vault = vault
    }
    public func prepare() async throws {
        if prepared { return }
        if let preparation { try await preparation.value; return }
        let task = Task { @MainActor in
            if let data = try vault.load(profileID: profileID) {
                for cookie in try CookieSnapshot(data: data).cookies() { await jar.setCookie(cookie) }
            }
            prepared = true
        }
        preparation = task
        do { try await task.value; preparation = nil }
        catch { preparation = nil; throw error }
    }
    public func checkpoint() async throws {
        try await prepare()
        needsCheckpoint = true
        if let checkpointTask { try await checkpointTask.value; return }
        let task = Task { @MainActor in
            defer { checkpointTask = nil }
            // Drain changes that arrive during a read before any close/quit caller returns.
            repeat {
                needsCheckpoint = false
                let cookies = await jar.allCookies()
                try vault.save(CookieSnapshot.capture(cookies).data, profileID: profileID)
            } while needsCheckpoint
        }
        checkpointTask = task
        try await task.value
    }
}
