import Darwin
import Foundation

/// Terminal input and output use UTF-8. Shells must use the same encoding,
/// including when launched from Finder without any locale environment.
struct TerminalEnvironment {
    static func utf8(_ inherited: [String: String]) -> [String: String] {
        func value(_ key: String) -> String? {
            guard let text = inherited[key], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return text
        }
        let all = value("LC_ALL"), ctype = value("LC_CTYPE"), language = value("LANG")
        let effective = all ?? ctype ?? language ?? "C"
        if isUTF8(effective) { return inherited }
        // Retain regional conventions where a corresponding UTF-8 locale exists.
        let region = effective.split(separator: ".", maxSplits: 1).first.map(String.init) ?? effective
        let candidates = [region + ".UTF-8", ctype, language, "en_US.UTF-8"].compactMap { $0 }
        let locale = candidates.first(where: isUTF8) ?? "en_US.UTF-8"
        var result = inherited
        result["LC_CTYPE"] = locale
        if all != nil { result["LC_ALL"] = locale }
        if language.map(isUTF8) != true { result["LANG"] = locale }
        return result
    }
    private static func isUTF8(_ name: String) -> Bool {
        // Validate with a locale object, without changing the app's global locale.
        guard let locale = newlocale(LC_CTYPE_MASK, name, nil) else { return false }
        defer { freelocale(locale) }
        let encoding = String(cString: nl_langinfo_l(CODESET, locale))
        return encoding.uppercased().replacingOccurrences(of: "-", with: "") == "UTF8"
    }
}
