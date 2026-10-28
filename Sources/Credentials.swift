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
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .notFound:   return "Claude Code is not logged in. Run `claude` and sign in."
        case .malformed:  return "Could not parse Claude Code credentials."
        case .saveFailed: return "Could not save the refreshed Claude token to Keychain."
        }
    }
}

/// Reads (and writes back) the OAuth session that Claude Code stores after login.
/// Primary: macOS Keychain item "Claude Code-credentials". Fallback: ~/.claude/.credentials.json.
enum CredentialsReader {
    static let service = "Claude Code-credentials"
    private static var loadedFromFile = false

    static func load() throws -> Credentials {
        if let data = readKeychain() {
            loadedFromFile = false
            return try parse(data)
        }
        if let data = readFile() {
            loadedFromFile = true
            return try parse(data)
        }
        throw CredentialsError.notFound
    }

    /// Persist refreshed tokens where they came from, keeping every other field intact.
    static func save(_ creds: Credentials, accessToken: String, refreshToken: String?, expiresAt: Date?) throws {
        var oauth = creds.raw
        oauth["accessToken"] = accessToken
        if let refreshToken { oauth["refreshToken"] = refreshToken }
        if let expiresAt { oauth["expiresAt"] = Int(expiresAt.timeIntervalSince1970 * 1000) }
        var root = creds.rootRaw
        root["claudeAiOauth"] = oauth
        let data = try JSONSerialization.data(withJSONObject: root, options: [])

        if loadedFromFile {
            let url = fileURL()
            try data.write(to: url, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } else {
            guard writeKeychain(data) else { throw CredentialsError.saveFailed }
        }
    }

    // MARK: Keychain via /usr/bin/security (survives Claude Code's own ACL rewrites)

    private static func readKeychain() -> Data? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-s", service, "-w"]
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

    /// `security -i` reads commands from stdin so the secret never appears in `ps`.
    private static func writeKeychain(_ data: Data) -> Bool {
        guard let json = String(data: data, encoding: .utf8), !json.contains("'") else { return false }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["-i"]
        let input = Pipe()
        proc.standardInput = input
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return false }
        let account = NSUserName()
        let line = "add-generic-password -U -s '\(service)' -a '\(account)' -w '\(json)'\n"
        input.fileHandleForWriting.write(Data(line.utf8))
        try? input.fileHandleForWriting.close()
        proc.waitUntilExit()
        return proc.terminationStatus == 0
    }

    // MARK: File fallback

    private static func fileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
    }

    private static func readFile() -> Data? { try? Data(contentsOf: fileURL()) }

    private static func parse(_ data: Data) throws -> Credentials {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { throw CredentialsError.malformed }

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
