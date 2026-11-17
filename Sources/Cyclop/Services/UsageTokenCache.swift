import Foundation

/// Keychain reads of Claude's and Cursor's items pop a password dialog for
/// any app that is not already on the item's ACL. A successful read is
/// cached in Cyclop's own folder so the next visit never asks.
enum UsageTokenCache {
    private static let url = Support.file("usage-tokens.json")

    static var claude: String? { read("claude") }
    static var cursor: String? { read("cursor") }

    static func storeClaude(_ token: String) { write("claude", token) }
    static func storeCursor(_ token: String) { write("cursor", token) }
    static func clearClaude() { write("claude", nil) }
    static func clearCursor() { write("cursor", nil) }

    /// Read through Apple's `security` tool, not SecItemCopyMatching. Claude
    /// Code writes its item with that same tool, so `/usr/bin/security` is
    /// already on the item's ACL and no dialog appears. For Cursor's item one
    /// "Always Allow" sticks to `/usr/bin/security`, whose identity survives
    /// Cyclop rebuilds — an ad-hoc signed Cyclop looks new on every build.
    static func keychain(service: String, account: String? = nil) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        var arguments = ["find-generic-password", "-s", service, "-w"]
        if let account { arguments += ["-a", account] }
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        var data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        while data.last == UInt8(ascii: "\n") { data.removeLast() }
        return data.isEmpty ? nil : data
    }

    private static func read(_ key: String) -> String? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let token = json[key], !token.isEmpty
        else { return nil }
        return token
    }

    private static func write(_ key: String, _ token: String?) {
        var json = (try? Data(contentsOf: url)).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: String]
        } ?? [:]
        if let token, !token.isEmpty {
            json[key] = token
        } else {
            json.removeValue(forKey: key)
        }
        if json.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
