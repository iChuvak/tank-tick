import Foundation

/// Keeps recent (time, percent) samples per quota window and derives the
/// *recent* consumption rate — the pace over the last ~30 minutes — rather
/// than the average since the window started.
///
/// Guards:
/// - samples from a previous reset cycle are discarded (keyed by `resetAt`)
/// - a gap longer than `maxGap` between samples (Mac asleep, app not running)
///   drops everything before the gap, so stale readings are never extrapolated
/// - a negative delta (provider corrections, delayed accounting) counts as zero
///   consumption, never as negative consumption
final class PaceTracker {
    struct Sample { let t: Date; let pct: Double; let resetAt: Date }

    enum Pace {
        /// Enough data; rate in percent per second (may be 0).
        case rate(Double)
        /// Not enough observed time yet; seconds until the minimum is met.
        case insufficient(secondsUntilReady: TimeInterval)
    }

    /// Lookback scales with the window so a weekly quota isn't driven by one
    /// busy half hour: window/10, clamped to 30 min … 6 h. Minimum observed
    /// time before a rate is reported is half the lookback.
    static func lookback(windowSeconds: TimeInterval) -> TimeInterval {
        min(max(windowSeconds / 10, 30 * 60), 6 * 60 * 60)
    }
    static func minimumObservation(windowSeconds: TimeInterval) -> TimeInterval {
        lookback(windowSeconds: windowSeconds) / 2
    }
    static let maxGap: TimeInterval = 20 * 60
    private let retention: TimeInterval = 13 * 60 * 60

    private var series: [String: [Sample]] = [:]

    func record(_ key: String, percent: Double, resetAt: Date?, at now: Date = Date()) {
        guard let resetAt else { series[key] = nil; return }
        var s = series[key] ?? []
        // New reset cycle → old samples are meaningless.
        if let last = s.last, abs(last.resetAt.timeIntervalSince(resetAt)) > 1 { s = [] }
        // Long gap (sleep, app was quit) → do not bridge it.
        if let last = s.last, now.timeIntervalSince(last.t) > Self.maxGap { s = [] }
        s.append(Sample(t: now, pct: percent, resetAt: resetAt))
        s = s.filter { now.timeIntervalSince($0.t) <= retention }
        series[key] = s
    }

    func pace(_ key: String, windowSeconds: TimeInterval, now: Date = Date()) -> Pace {
        let lookback = Self.lookback(windowSeconds: windowSeconds)
        let minimum = Self.minimumObservation(windowSeconds: windowSeconds)
        guard let s = series[key], let latest = s.last else {
            return .insufficient(secondsUntilReady: minimum)
        }
        // Oldest sample inside the lookback window is the reference point.
        let inWindow = s.filter { now.timeIntervalSince($0.t) <= lookback }
        guard let ref = inWindow.first else {
            return .insufficient(secondsUntilReady: minimum)
        }
        let observed = latest.t.timeIntervalSince(ref.t)
        guard observed >= minimum else {
            return .insufficient(secondsUntilReady: minimum - observed)
        }
        let delta = max(0, latest.pct - ref.pct)
        return .rate(delta / observed)
    }
}
