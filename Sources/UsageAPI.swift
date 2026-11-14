import Foundation

struct UsageWindow: Decodable {
    let utilization: Double?      // percent, 0...100
    let resetsAt: String?

    var resetDate: Date? {
        guard let s = resetsAt else { return nil }
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: s) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: s)
    }
}

struct ExtraUsage: Decodable {
    let isEnabled: Bool?
    let monthlyLimit: Double?
    let usedCredits: Double?
    let utilization: Double?
    let currency: String?
}

struct UsageResponse: Decodable {
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow?
    let sevenDayOpus: UsageWindow?
    let sevenDaySonnet: UsageWindow?
    let extraUsage: ExtraUsage?
}

enum UsageError: LocalizedError {
    case tokenExpired
    case rateLimited
    case http(Int)
    case network(String)
    case refreshFailed(Int)
    case claudeTokenExpired

    var errorDescription: String? {
        switch self {
        case .tokenExpired: return "Token expired and could not be refreshed. Sign in again in the CLI."
        case .refreshFailed(let c): return "Token refresh failed (HTTP \(c)). Sign in again in the CLI."
        case .claudeTokenExpired: return "Claude token expired. Run `claude` once — it refreshes the token."
        case .rateLimited:  return "Rate limited (429). Backing off and retrying later."
        case .http(let c):  return "Server error: HTTP \(c)"
        case .network(let m): return "Network error: \(m)"
        }
    }
}

enum UsageAPI {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    static func fetch(creds: Credentials, completion: @escaping (Result<UsageResponse, Error>) -> Void) {
        var req = URLRequest(url: endpoint, timeoutInterval: 20)
        req.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("TankTick/1.3", forHTTPHeaderField: "User-Agent")

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
            do {
                completion(.success(try dec.decode(UsageResponse.self, from: data ?? Data())))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }
}
