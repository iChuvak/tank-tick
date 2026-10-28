import Foundation

// MARK: - Codex (ChatGPT plan) credentials: ~/.codex/auth.json

struct CodexCredentials {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
    let accountId: String?
    let planType: String?
    let expiresAt: Date?
    let rootRaw: [String: Any]
    let fileURL: URL

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSinceNow < 60
    }
}

enum CodexCredentialsError: LocalizedError {
    case notFound, malformed
    var errorDescription: String? {
        switch self {
        case .notFound:  return "Codex CLI is not logged in. Run `codex login`."
        case .malformed: return "Could not parse ~/.codex/auth.json."
        }
    }
}

enum CodexCredentialsReader {
    static func load() throws -> CodexCredentials {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let url = home.appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: url) else { throw CodexCredentialsError.notFound }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let access = (tokens["access_token"] ?? tokens["accessToken"]) as? String, !access.isEmpty
        else { throw CodexCredentialsError.malformed }

        let idToken = (tokens["id_token"] ?? tokens["idToken"]) as? String
        let claims = jwtPayload(idToken) ?? jwtPayload(access) ?? [:]
        let auth = claims["https://api.openai.com/auth"] as? [String: Any]

        let accountId = (tokens["account_id"] ?? tokens["accountId"]) as? String
            ?? auth?["chatgpt_account_id"] as? String
            ?? claims["chatgpt_account_id"] as? String
        let plan = auth?["chatgpt_plan_type"] as? String ?? claims["chatgpt_plan_type"] as? String
        let exp = (jwtPayload(access)?["exp"] as? Double).map { Date(timeIntervalSince1970: $0) }
        return CodexCredentials(accessToken: access,
                                refreshToken: (tokens["refresh_token"] ?? tokens["refreshToken"]) as? String,
                                idToken: idToken, accountId: accountId, planType: plan,
                                expiresAt: exp, rootRaw: root, fileURL: url)
    }

    /// Write refreshed tokens back to auth.json, preserving other keys (same shape Codex writes).
    static func save(_ creds: CodexCredentials, accessToken: String, refreshToken: String?, idToken: String?) throws {
        var root = creds.rootRaw
        var tokens = root["tokens"] as? [String: Any] ?? [:]
        tokens["access_token"] = accessToken
        if let refreshToken { tokens["refresh_token"] = refreshToken }
        if let idToken { tokens["id_token"] = idToken }
        if let id = creds.accountId { tokens["account_id"] = id }
        root["tokens"] = tokens
        root["last_refresh"] = ISO8601DateFormatter().string(from: Date())
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: creds.fileURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: creds.fileURL.path)
    }

    private static func jwtPayload(_ jwt: String?) -> [String: Any]? {
        guard let jwt else { return nil }
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let d = Data(base64Encoded: b64) else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }
}

// MARK: - Token refresh (same flow the Codex CLI uses)

enum CodexOAuth {
    static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    static func refresh(_ creds: CodexCredentials, completion: @escaping (Result<CodexCredentials, Error>) -> Void) {
        guard let rt = creds.refreshToken, !rt.isEmpty else {
            completion(.failure(UsageError.tokenExpired)); return
        }
        var req = URLRequest(url: tokenURL, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "client_id": clientID, "grant_type": "refresh_token",
            "refresh_token": rt, "scope": "openid profile email"])

        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err { completion(.failure(UsageError.network(err.localizedDescription))); return }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200,
                  let json = try? JSONSerialization.jsonObject(with: data ?? Data()) as? [String: Any],
                  let access = json["access_token"] as? String, !access.isEmpty
            else { completion(.failure(UsageError.refreshFailed(code))); return }
            let newRefresh = json["refresh_token"] as? String
            let newId = json["id_token"] as? String ?? creds.idToken
            do { try CodexCredentialsReader.save(creds, accessToken: access, refreshToken: newRefresh, idToken: newId) }
            catch { completion(.failure(error)); return }
            // Re-read so account id / plan / expiry come from the fresh token.
            do { completion(.success(try CodexCredentialsReader.load())) }
            catch { completion(.failure(error)) }
        }.resume()
    }
}

// MARK: - Usage endpoint: GET https://chatgpt.com/backend-api/wham/usage

struct CodexWindow: Decodable {
    let usedPercent: Double?
    let resetAt: Double?            // unix seconds
    let limitWindowSeconds: Double?

    var resetDate: Date? { resetAt.map { Date(timeIntervalSince1970: $0) } }
}

struct CodexRateLimit: Decodable {
    let primaryWindow: CodexWindow?
    let secondaryWindow: CodexWindow?
}

struct CodexUsageResponse: Decodable {
    let planType: String?
    let rateLimit: CodexRateLimit?
}

enum CodexAPI {
    static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    static func fetch(creds: CodexCredentials, completion: @escaping (Result<CodexUsageResponse, Error>) -> Void) {
        var req = URLRequest(url: endpoint, timeoutInterval: 20)
        req.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("ClaudeUsageBar/1.0", forHTTPHeaderField: "User-Agent")
        if let id = creds.accountId, !id.isEmpty {
            req.setValue(id, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err { completion(.failure(UsageError.network(err.localizedDescription))); return }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 200: break
            case 401, 403: completion(.failure(UsageError.tokenExpired)); return
            case 429: completion(.failure(UsageError.rateLimited)); return
            default: completion(.failure(UsageError.http(code))); return
            }
            let dec = JSONDecoder()
            dec.keyDecodingStrategy = .convertFromSnakeCase
            do { completion(.success(try dec.decode(CodexUsageResponse.self, from: data ?? Data()))) }
            catch { completion(.failure(error)) }
        }.resume()
    }
}
