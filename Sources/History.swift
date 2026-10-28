import Foundation

/// Daily peaks of each usage window, kept locally for 30 days.
/// File: ~/Library/Application Support/ClaudeUsageBar/history.json
/// Shape: { "claude5h": { "2026-10-29": { "peak": 61.0, "at": 1761734400 } }, "gpt5h": { ... } }
final class UsageHistory {
    struct DayPeak: Codable { var peak: Double; var at: TimeInterval }
    typealias Series = [String: DayPeak]          // dayKey -> peak

    private var data: [String: Series] = [:]
    private let url: URL
    private let keepDays = 30

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ClaudeUsageBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent("history.json")
        if let d = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: Series].self, from: d) {
            data = decoded
        }
    }

    static func dayKey(_ date: Date) -> String { dayFormatter.string(from: date) }

    /// Record a sample; keeps the day's maximum.
    func record(_ series: String, percent: Double, at date: Date = Date()) {
        let key = Self.dayKey(date)
        var s = data[series] ?? [:]
        if let existing = s[key], existing.peak >= percent { return }
        s[key] = DayPeak(peak: percent, at: date.timeIntervalSince1970)
        data[series] = s
        prune()
        save()
    }

    /// Last `days` days, oldest first; nil where there is no sample.
    func recent(_ series: String, days: Int) -> [(date: Date, peak: DayPeak?)] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let s = data[series] ?? [:]
        return (0..<days).reversed().map { back in
            let d = cal.date(byAdding: .day, value: -back, to: today)!
            return (d, s[Self.dayKey(d)])
        }
    }

    private func prune() {
        let cutoff = Calendar.current.date(byAdding: .day, value: -keepDays, to: Date())!
        let cutKey = Self.dayKey(cutoff)
        for (k, s) in data { data[k] = s.filter { $0.key >= cutKey } }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(data) { try? d.write(to: url, options: [.atomic]) }
    }
}
