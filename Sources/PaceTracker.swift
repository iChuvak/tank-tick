import Foundation

/// Keeps recent (time, percent) samples per quota window and derives the
/// *recent* consumption rate — the pace over the last lookback — rather
/// than the average since the window started.
///
/// Samples are persisted to ~/Library/Application Support/TankTick/pace.json
/// so a relaunch does not reset the forecast.
///
/// Guards:
/// - samples from a previous reset cycle are discarded (keyed by `resetAt`)
/// - a gap longer than `maxGap` between consecutive samples (Mac asleep, app
///   not running) is never bridged: only the samples after the gap count
/// - a negative delta (provider corrections, delayed accounting) counts as
///   zero consumption, never as negative consumption
final class PaceTracker {
    struct Sample: Codable { let t: Date; let pct: Double; let resetAt: Date }

    enum Pace {
        /// Enough data; rate in percent per second (may be 0).
        case rate(Double)
        /// Not enough observed time yet; seconds until the minimum is met.
        case insufficient(secondsUntilReady: TimeInterval)
    }

    /// Lookback scales with the window so a weekly quota isn't driven by one
    /// busy half hour: window/10, clamped to 30 min … 6 h.
    static func lookback(windowSeconds: TimeInterval) -> TimeInterval {
        min(max(windowSeconds / 10, 30 * 60), 6 * 60 * 60)
    }
    /// Minimum observed time before a rate is reported: half the lookback.
    static func minimumObservation(windowSeconds: TimeInterval) -> TimeInterval {
        lookback(windowSeconds: windowSeconds) / 2
    }
    /// Largest gap between samples that still counts as continuous observation:
    /// 20 min for a 5h window, 2 h for a weekly one.
    static func maxGap(windowSeconds: TimeInterval) -> TimeInterval {
        max(20 * 60, lookback(windowSeconds: windowSeconds) / 3)
    }
    private let retention: TimeInterval = 13 * 60 * 60

    private var series: [String: [Sample]] = [:]
    private let url: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("TankTick", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent("pace.json")
        if let d = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: [Sample]].self, from: d) {
            series = decoded
        }
    }

    func record(_ key: String, percent: Double, resetAt: Date?, at now: Date = Date()) {
        guard let resetAt else { series[key] = nil; save(); return }
        var s = series[key] ?? []
        // New reset cycle → old samples are meaningless.
        if let last = s.last, abs(last.resetAt.timeIntervalSince(resetAt)) > 1 { s = [] }
        s.append(Sample(t: now, pct: percent, resetAt: resetAt))
        s = s.filter { now.timeIntervalSince($0.t) <= retention }
        series[key] = s
        save()
    }

    func pace(_ key: String, windowSeconds: TimeInterval, now: Date = Date()) -> Pace {
        let lookback = Self.lookback(windowSeconds: windowSeconds)
        let minimum = Self.minimumObservation(windowSeconds: windowSeconds)
        let maxGap = Self.maxGap(windowSeconds: windowSeconds)
        guard let all = series[key], let latest = all.last else {
            return .insufficient(secondsUntilReady: minimum)
        }
        // Walk back from the latest sample while samples are contiguous and
        // inside the lookback; the oldest such sample is the reference point.
        var ref = latest
        for sample in all.dropLast().reversed() {
            guard now.timeIntervalSince(sample.t) <= lookback,
                  ref.t.timeIntervalSince(sample.t) <= maxGap else { break }
            ref = sample
        }
        let observed = latest.t.timeIntervalSince(ref.t)
        guard observed >= minimum else {
            return .insufficient(secondsUntilReady: minimum - observed)
        }
        let delta = max(0, latest.pct - ref.pct)
        return .rate(delta / observed)
    }

    private func save() {
        if let d = try? JSONEncoder().encode(series) { try? d.write(to: url, options: [.atomic]) }
    }
}
