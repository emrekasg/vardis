import CryptoKit
import Foundation
import Security
import VardisCore

/// Reads the Claude Code OAuth access token. Only the access token is ever returned; the refresh token is never
/// read into a value that leaves this file, and nothing here logs.
public enum ClaudeCredentials {
    public static let defaultService = "Claude Code-credentials"

    /// Keychain service Claude Code uses for a config dir. `~/.claude` uses the plain name; a custom
    /// `CLAUDE_CONFIG_DIR` gets `-<first 8 hex of sha256(path)>` appended (Claude Code behaviour, not
    /// verifiable on a machine that only has the default home).
    public static func keychainService(for home: ClaudeHome) -> String {
        if home.isDefault { return defaultService }
        let digest = SHA256.hash(data: Data(home.url.path.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return defaultService + "-" + hex.prefix(8)
    }

    /// Keychain first (direct edition), then `<home>/.credentials.json`. Expired tokens are returned as nil.
    public static func readAccessToken(home: ClaudeHome, now: Date = Date()) -> String? {
        if Edition.current.supports(.keychainDiscovery), let data = keychainData(service: keychainService(for: home)),
           let token = accessToken(fromJSON: data, now: now) {
            return token
        }
        if let data = try? Data(contentsOf: home.url.appendingPathComponent(".credentials.json")) {
            return accessToken(fromJSON: data, now: now)
        }
        return nil
    }

    /// Parses `{"claudeAiOauth":{"accessToken":…,"expiresAt":<ms since 1970>}}`.
    static func accessToken(fromJSON data: Data, now: Date) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        if let ms = (oauth["expiresAt"] as? NSNumber)?.doubleValue, Date(timeIntervalSince1970: ms / 1000) <= now { return nil }
        return token
    }

    private static func keychainData(service: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }
}
