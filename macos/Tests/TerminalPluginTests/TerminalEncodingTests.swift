import Darwin
import Foundation
@testable import TerminalPlugin

final class TerminalEncodingTests {
    func testLocalePolicy() throws {
        for input in [[String: String](), ["LANG": "C"], ["LC_ALL": "C", "LANG": "ru_RU.UTF-8"],
                      ["LC_CTYPE": "POSIX"], ["LANG": "en_US.US-ASCII"], ["LANG": "invalid.UTF-8"]] {
            let result = TerminalEnvironment.utf8(input)
            let name = result["LC_ALL"] ?? result["LC_CTYPE"] ?? result["LANG"] ?? "C"
            guard let locale = newlocale(LC_CTYPE_MASK, name, nil) else {
                throw NSError(domain: "InvalidTerminalLocale", code: 1)
            }
            defer { freelocale(locale) }
            let encoding = String(cString: nl_langinfo_l(CODESET, locale)).uppercased().replacingOccurrences(of: "-", with: "")
            try expectEqual(encoding, "UTF8")
            try expectEqual(TerminalEnvironment.utf8(result), result)
        }
        for input in [["LANG": "ru_RU.UTF-8", "HOME": "/tmp", "LC_TIME": "C"],
                      ["LC_ALL": "en_US.UTF-8", "LC_CTYPE": "C"]] {
            try expectEqual(TerminalEnvironment.utf8(input), input)
        }
    }
    @MainActor func testRussianInputWithGUIEnvironment() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Russian terminal \(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let text = "Привет, мир! Ёжик"
        for override in [false, true] {
            var environment = ["HOME": folder.path, "ZDOTDIR": folder.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
            if override { environment["LC_ALL"] = "C" }
            let session = TerminalSession(configuration: TerminalConfiguration(shell: "/bin/zsh", workingDirectory: folder.path, startupCommands: ["printf '__RUSSIAN_READY__\\n'"]), environment: environment)
            var output = Data(); session.onOutput = { output.append($0) }
            defer { session.stop() }
            // Keep the command on one line so the raw echo assertion excludes
            // zsh screen-wrap/redraw escape sequences.
            try session.resize(columns: 512, rows: 24)
            try session.start()
            let readyDeadline = Date().addingTimeInterval(10)
            while !String(decoding: output, as: UTF8.self).contains("__RUSSIAN_READY__\r\n") {
                if Date() > readyDeadline { throw NSError(domain: "RussianTerminalReadyTimeout", code: 1) }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            output.removeAll()
            session.send(Data("locale charmap > encoding; studio_text='\(text)'; printf '%s' \"$studio_text\" > russian; printf '%s' \"${#studio_text}\" > length; exit\n".utf8))
            let deadline = Date().addingTimeInterval(10)
            while session.processID != nil {
                if Date() > deadline { throw NSError(domain: "RussianTerminalTimeout", code: 1) }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            try expectEqual(session.state, .exited(0))
            try expectNotNil(output.range(of: Data(text.utf8)))
            let encoding = try String(contentsOf: folder.appendingPathComponent("encoding")).trimmingCharacters(in: .whitespacesAndNewlines)
            try expectEqual(encoding.uppercased().replacingOccurrences(of: "-", with: ""), "UTF8")
            try expectEqual(try Data(contentsOf: folder.appendingPathComponent("russian")), Data(text.utf8))
            try expectEqual(try String(contentsOf: folder.appendingPathComponent("length")), String(text.count))
        }
    }
}
