import Foundation

struct Credentials {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?
    let subscriptionType: String?
    /// The full `claudeAiOauth` object as stored, so a write‑back preserves unknown keys.
    let raw: [String: Any]
    let rootRaw: [String: Any]

    /// Treat the token as expired a minute early to avoid racing the server clock.
    var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSinceNow < 60
    }
}

enum CredentialsError: LocalizedError {
    case notFound
    case malformed
    case sessionExpired

    var errorDescription: String? {
        switch self {
        case .notFound:   return "Claude Code is not logged in. Run `claude` and sign in."
        case .malformed:  return "Claude Code login unreadable. Run `claude` and sign in again."
        case .sessionExpired: return "Claude Code session expired. Run `claude`, then /login."
        }
    }
}

/// Reads (never writes) the OAuth session that Claude Code stores after login.
/// Primary: macOS Keychain item "Claude Code-credentials". Fallback: ~/.claude/.credentials.json.
enum CredentialsReader {
    static let service = "Claude Code-credentials"

    static func load() throws -> Credentials {
        if let data = readKeychain() {
            return try parse(data)
        }
        if let data = readFile() {
            return try parse(data)
        }
        throw CredentialsError.notFound
    }

    // MARK: Keychain via /usr/bin/security (survives Claude Code's own ACL rewrites)

    /// Claude Code stores the item under the login user's account name. If more
    /// than one item with this service exists, the account pins the right one;
    /// fall back to any account for older setups.
    private static func readKeychain() -> Data? {
        readKeychain(account: NSUserName()) ?? readKeychain(account: nil)
    }

    private static func readKeychain(account: String?) -> Data? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        var args = ["find-generic-password", "-s", service]
        if let account { args += ["-a", account] }
        proc.arguments = args + ["-w"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        if let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !str.isEmpty {
            return str.data(using: .utf8)
        }
        return nil
    }

    // MARK: File fallback

    private static func fileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
    }

    private static func readFile() -> Data? { try? Data(contentsOf: fileURL()) }

    private static func parse(_ data: Data) throws -> Credentials {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any]
        else { throw CredentialsError.malformed }
        // The record is intact but the session is gone: Claude Code blanks the
        // access token when its refresh fails, and newer builds also store
        // refreshTokenExpiresAt. Either way only `/login` in Claude Code helps.
        if let rtExp = oauth["refreshTokenExpiresAt"] as? Double,
           Date(timeIntervalSince1970: rtExp / 1000) <= Date() {
            throw CredentialsError.sessionExpired
        }
        guard let token = oauth["accessToken"] as? String, !token.isEmpty
        else { throw CredentialsError.sessionExpired }

        var expires: Date? = nil
        if let ms = oauth["expiresAt"] as? Double {
            expires = Date(timeIntervalSince1970: ms / 1000)
        }
        return Credentials(accessToken: token,
                           refreshToken: oauth["refreshToken"] as? String,
                           expiresAt: expires,
                           subscriptionType: oauth["subscriptionType"] as? String,
                           raw: oauth, rootRaw: root)
    }
}
