import AppKit
import ServiceManagement
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var timer: Timer?
    private var menuIsOpen = false
    private var menuNeedsRebuild = false

    // Claude
    private var claude: UsageResponse?
    private var claudeError: String?
    private var claudePlan: String?

    // Codex / ChatGPT
    private var codex: CodexUsageResponse?
    private var codexError: String?
    private var codexPlan: String?
    private var codexLoggedIn = true

    private var lastUpdated: Date?
    private var refreshing = false
    private let history = UsageHistory()

    /// Both usage endpoints rate‑limit aggressively; poll conservatively and
    /// back off further after a 429.
    private let normalInterval: TimeInterval = 5 * 60
    private var currentInterval: TimeInterval = 5 * 60

    /// Alert thresholds (percent used). Each fires once per reset window.
    private let thresholds: [Double] = [80, 95]
    private var notified = Set<String>()      // "window-key|resetAt|threshold"
    private var notificationsAllowed = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.image = stackedImage(top: nil, bottom: nil)
        menu.delegate = self
        statusItem.menu = menu
        rebuildMenu()

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] ok, _ in
            DispatchQueue.main.async { self?.notificationsAllowed = ok }
        }

        // Refresh right after the Mac wakes up instead of waiting for the next tick.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self?.refresh() }
        }

        refresh()
    }

    // Show banners even while the app is "active" (it's always a background app anyway).
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler handler: @escaping (UNNotificationPresentationOptions) -> Void) {
        handler([.banner, .sound])
    }

    // MARK: - Data

    @objc func refresh() {
        guard !refreshing else { return }
        refreshing = true
        timer?.invalidate()
        let group = DispatchGroup()
        var hitRateLimit = false

        // Claude — refresh the token first if it has expired, then fetch; a 401 also triggers one refresh.
        group.enter()
        fetchClaude(allowRefresh: true) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let u): self?.claude = u; self?.claudeError = nil
                case .failure(let e):
                    if case UsageError.rateLimited = e { hitRateLimit = true }
                    self?.claudeError = e.localizedDescription
                }
                group.leave()
            }
        }

        // Codex (ChatGPT plan)
        group.enter()
        fetchCodex(allowRefresh: true) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let u):
                    self?.codex = u; self?.codexError = nil; self?.codexLoggedIn = true
                    if let p = u.planType { self?.codexPlan = p }
                case .failure(let e):
                    if case UsageError.rateLimited = e { hitRateLimit = true }
                    if case CodexCredentialsError.notFound = e { self?.codexLoggedIn = false } else { self?.codexLoggedIn = true }
                    self?.codexError = e.localizedDescription
                }
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            self.refreshing = false
            self.lastUpdated = Date()
            self.currentInterval = hitRateLimit ? min(self.currentInterval * 2, 30 * 60) : self.normalInterval
            self.recordHistory()
            self.updateButton()
            self.rebuildMenuIfPossible()
            self.checkThresholds()
            self.schedule()
        }
    }

    private func fetchClaude(allowRefresh: Bool, completion: @escaping (Result<UsageResponse, Error>) -> Void) {
        let creds: Credentials
        do { creds = try CredentialsReader.load() } catch { completion(.failure(error)); return }
        claudePlan = creds.subscriptionType

        func run(_ c: Credentials, retryOn401: Bool) {
            UsageAPI.fetch(creds: c) { result in
                if retryOn401, case .failure(let e) = result, case UsageError.tokenExpired = e {
                    ClaudeOAuth.refresh(c) { r in
                        switch r {
                        case .success(let fresh): run(fresh, retryOn401: false)
                        case .failure(let err): completion(.failure(err))
                        }
                    }
                } else { completion(result) }
            }
        }

        if creds.isExpired && allowRefresh {
            ClaudeOAuth.refresh(creds) { r in
                switch r {
                case .success(let fresh): run(fresh, retryOn401: false)
                case .failure(let err): completion(.failure(err))
                }
            }
        } else {
            run(creds, retryOn401: allowRefresh)
        }
    }

    private func fetchCodex(allowRefresh: Bool, completion: @escaping (Result<CodexUsageResponse, Error>) -> Void) {
        let creds: CodexCredentials
        do { creds = try CodexCredentialsReader.load() } catch { completion(.failure(error)); return }
        if let p = creds.planType { codexPlan = p }

        func run(_ c: CodexCredentials, retryOn401: Bool) {
            CodexAPI.fetch(creds: c) { result in
                if retryOn401, case .failure(let e) = result, case UsageError.tokenExpired = e {
                    CodexOAuth.refresh(c) { r in
                        switch r {
                        case .success(let fresh): run(fresh, retryOn401: false)
                        case .failure(let err): completion(.failure(err))
                        }
                    }
                } else { completion(result) }
            }
        }

        if creds.isExpired && allowRefresh {
            CodexOAuth.refresh(creds) { r in
                switch r {
                case .success(let fresh): run(fresh, retryOn401: false)
                case .failure(let err): completion(.failure(err))
                }
            }
        } else {
            run(creds, retryOn401: allowRefresh)
        }
    }

    private func schedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(timeInterval: currentInterval, target: self,
                                     selector: #selector(refresh), userInfo: nil, repeats: false)
        timer?.tolerance = 30
    }

    // MARK: - Notifications

    private func checkThresholds() {
        guard notificationsAllowed else { return }
        var windows: [(key: String, title: String, pct: Double?, reset: Date?)] = [
            ("claude5h", "Claude · session (5h)", claude?.fiveHour?.utilization, claude?.fiveHour?.resetDate),
            ("claude7d", "Claude · week", claude?.sevenDay?.utilization, claude?.sevenDay?.resetDate),
        ]
        if let r = codex?.rateLimit {
            windows.append(("gpt5h", "ChatGPT · session (5h)", r.primaryWindow?.usedPercent, r.primaryWindow?.resetDate))
            windows.append(("gpt7d", "ChatGPT · week", r.secondaryWindow?.usedPercent, r.secondaryWindow?.resetDate))
        }
        for w in windows {
            guard let pct = w.pct else { continue }
            let resetKey = w.reset.map { String(Int($0.timeIntervalSince1970)) } ?? "none"
            // Only the highest crossed threshold fires, once per reset window.
            guard let t = thresholds.filter({ pct >= $0 }).max() else { continue }
            let id = "\(w.key)|\(resetKey)|\(Int(t))"
            guard !notified.contains(id) else { continue }
            // Mark lower thresholds as done too, so 80% doesn't fire after 95%.
            for lower in thresholds where lower <= t { notified.insert("\(w.key)|\(resetKey)|\(Int(lower))") }
            notify(title: "\(w.title): \(Int(pct.rounded()))% used",
                   body: w.reset.map { "Resets \(relative($0)) · \(absolute($0))" } ?? "")
        }
        // Keep the set small: drop entries for windows that have already reset.
        let now = Int(Date().timeIntervalSince1970)
        notified = notified.filter { id in
            let parts = id.split(separator: "|")
            guard parts.count == 3, let reset = Int(parts[1]) else { return true }
            return reset > now
        }
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    // MARK: - Menubar

    /// Muted palette; slightly lighter variants in dark mode for legibility.
    private static func dynamic(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.0/255, green: c.1/255, blue: c.2/255, alpha: 1)
        }
    }
    private static let mutedGreen = dynamic(light: (96, 150, 112), dark: (128, 178, 142))
    private static let mutedAmber = dynamic(light: (190, 146, 70),  dark: (212, 170, 96))
    private static let mutedRed   = dynamic(light: (180, 92, 84),   dark: (208, 120, 112))

    private func color(for pct: Double) -> NSColor {
        switch pct {
        case ..<50: return Self.mutedGreen
        case ..<80: return Self.mutedAmber
        default:    return Self.mutedRed
        }
    }

    /// Claude 5‑hour window on top, ChatGPT 5‑hour window below. When Codex isn't
    /// logged in at all, only the Claude number is shown (centred, larger).
    private func stackedImage(top: Double?, bottom: Double?) -> NSImage {
        func line(_ v: Double?, size: CGFloat) -> NSAttributedString {
            let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold)
            let text = v.map { "\(Int($0.rounded()))%" } ?? "—"
            let col: NSColor = v.map { color(for: $0) } ?? .secondaryLabelColor
            return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: col])
        }
        let img: NSImage
        if codexLoggedIn {
            let a = line(top, size: 9), b = line(bottom, size: 9)
            let w = max(a.size().width, b.size().width, 20)
            img = NSImage(size: NSSize(width: w, height: 22), flipped: false) { rect in
                a.draw(at: NSPoint(x: (rect.width - a.size().width) / 2, y: 11))
                b.draw(at: NSPoint(x: (rect.width - b.size().width) / 2, y: 0.5))
                return true
            }
        } else {
            let a = line(top, size: 12)
            let w = max(a.size().width, 20)
            img = NSImage(size: NSSize(width: w, height: 22), flipped: false) { rect in
                a.draw(at: NSPoint(x: (rect.width - a.size().width) / 2, y: (rect.height - a.size().height) / 2))
                return true
            }
        }
        img.isTemplate = false
        return img
    }

    private func updateButton() {
        guard let button = statusItem.button else { return }
        let claude5h = claude?.fiveHour?.utilization
        let gpt5h = codex?.rateLimit?.primaryWindow?.usedPercent
        button.image = stackedImage(top: claude5h, bottom: gpt5h)

        func describe(_ pct: Double?, _ reset: Date?) -> String {
            guard let pct else { return "—" }
            var s = "\(Int(pct.rounded()))%"
            if let reset { s += ", resets \(relative(reset))" }
            return s
        }
        var tip = "Claude 5h: " + describe(claude5h, claude?.fiveHour?.resetDate)
        if codexLoggedIn {
            tip += "\nChatGPT 5h: " + describe(gpt5h, codex?.rateLimit?.primaryWindow?.resetDate)
        }
        button.toolTip = tip
    }

    // MARK: - Menu

    private func rebuildMenuIfPossible() {
        if menuIsOpen { menuNeedsRebuild = true } else { rebuildMenu() }
    }

    private func rebuildMenu() {
        menuNeedsRebuild = false
        menu.removeAllItems()

        // Claude section
        menu.addItem(header("Claude" + (claudePlan.map { " · \($0.capitalized)" } ?? "")))
        if let u = claude {
            addWindow("Session (5h)", u.fiveHour?.utilization, u.fiveHour?.resetDate, windowSeconds: 5 * 3600)
            addWindow("Week · all models", u.sevenDay?.utilization, u.sevenDay?.resetDate, windowSeconds: 7 * 86400)
            if let o = u.sevenDayOpus, o.utilization != nil { addWindow("Week · Opus", o.utilization, o.resetDate, windowSeconds: 7 * 86400) }
            if let s = u.sevenDaySonnet, s.utilization != nil { addWindow("Week · Sonnet", s.utilization, s.resetDate, windowSeconds: 7 * 86400) }
            if let x = u.extraUsage, x.isEnabled == true {
                let t = String(format: "Extra usage: %.2f / %.2f %@ (%d%%)",
                               x.usedCredits ?? 0, x.monthlyLimit ?? 0, x.currency ?? "USD",
                               Int((x.utilization ?? 0).rounded()))
                menu.addItem(disabled(t))
            }
            addHistory(series: "claude5h")
        } else {
            menu.addItem(disabled("No data"))
        }
        if let e = claudeError { menu.addItem(errorItem(e)) }

        menu.addItem(.separator())

        // ChatGPT / Codex section
        menu.addItem(header("ChatGPT · Codex" + (codexPlan.map { " · \($0.capitalized)" } ?? "")))
        if let r = codex?.rateLimit {
            addWindow("Session (5h)", r.primaryWindow?.usedPercent, r.primaryWindow?.resetDate,
                      windowSeconds: r.primaryWindow?.limitWindowSeconds ?? 5 * 3600)
            addWindow("Week", r.secondaryWindow?.usedPercent, r.secondaryWindow?.resetDate,
                      windowSeconds: r.secondaryWindow?.limitWindowSeconds ?? 7 * 86400)
            addHistory(series: "gpt5h")
        } else if codexError == nil {
            menu.addItem(disabled("No data"))
        }
        if let e = codexError { menu.addItem(errorItem(e)) }

        menu.addItem(.separator())
        if let lastUpdated {
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            menu.addItem(disabled("Updated at \(f.string(from: lastUpdated))"))
        }

        menu.addItem(.separator())
        menu.addItem(action("Refresh now", #selector(refresh), key: "r"))
        menu.addItem(action("Open Claude usage page", #selector(openClaudeUsage)))
        menu.addItem(action("Open ChatGPT usage page", #selector(openChatGPTUsage)))

        if #available(macOS 13.0, *) {
            let login = action("Launch at login", #selector(toggleLogin))
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
            menu.addItem(login)
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func addWindow(_ name: String, _ pct: Double?, _ reset: Date?, windowSeconds: Double? = nil) {
        guard let pct else { menu.addItem(disabled("\(name): —")); return }
        var sub = ""
        if let reset { sub = "resets \(relative(reset)) · \(absolute(reset))" }
        let pace = paceLine(pct: pct, reset: reset, windowSeconds: windowSeconds)
        let item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
        item.view = UsageRowView(title: name, percent: pct, subtitle: sub, pace: pace,
                                 color: color(for: pct), paceColor: pace.1)
        item.isEnabled = false
        menu.addItem(item)
    }

    /// Burn‑rate projection: given how much of the window has elapsed and how much
    /// quota is used, estimate whether the quota runs out before the reset.
    /// Returns (text, colour); text is empty when there's nothing meaningful to say.
    private func paceLine(pct: Double, reset: Date?, windowSeconds: Double?) -> (String, NSColor) {
        guard let reset, let len = windowSeconds, len > 0 else { return ("", .secondaryLabelColor) }
        let now = Date()
        let start = reset.addingTimeInterval(-len)
        let elapsed = now.timeIntervalSince(start)
        let remaining = reset.timeIntervalSince(now)
        guard elapsed > 15 * 60, remaining > 0 else { return ("", .secondaryLabelColor) }
        if pct >= 100 { return ("limit reached · wait for reset", Self.mutedRed) }
        if pct < 1 { return ("", .secondaryLabelColor) }

        let rate = pct / elapsed                    // % per second
        let secondsToEmpty = (100 - pct) / rate
        let projectedAtReset = min(pct + rate * remaining, 999)

        // "Forecast" = usage expected when the window resets, extrapolating the
        // current pace (an estimate‑at‑completion, in project‑management terms).
        if secondsToEmpty < remaining {
            let when = now.addingTimeInterval(secondsToEmpty)
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            let dayPrefix = Calendar.current.isDateInToday(when) ? "" : "\(absolute(when).components(separatedBy: ",").first ?? "") "
            return ("Forecast: 100% by ~\(dayPrefix)\(f.string(from: when)) · before reset",
                    projectedAtReset > 130 ? Self.mutedRed : Self.mutedAmber)
        } else {
            let verdict = projectedAtReset > 85 ? "tight" : "fits"
            return ("Forecast at reset: ~\(Int(projectedAtReset.rounded()))% · \(verdict)",
                    projectedAtReset > 85 ? Self.mutedAmber : Self.mutedGreen)
        }
    }

    // MARK: - History

    private func recordHistory() {
        if let p = claude?.fiveHour?.utilization { history.record("claude5h", percent: p) }
        if let p = codex?.rateLimit?.primaryWindow?.usedPercent { history.record("gpt5h", percent: p) }
    }

    private var historyExpanded: Bool {
        get { UserDefaults.standard.bool(forKey: "historyExpanded") }
        set { UserDefaults.standard.set(newValue, forKey: "historyExpanded") }
    }

    private func addHistory(series: String) {
        let days = history.recent(series, days: 7)
        let samples = days.compactMap { $0.peak }
        guard !samples.isEmpty else { return }

        let best = days.max { ($0.peak?.peak ?? -1) < ($1.peak?.peak ?? -1) }!
        var caption = "Last 7 days"
        if let bp = best.peak, bp.peak >= 1 {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "EEE HH:mm"
            caption += " · peak \(Int(bp.peak.rounded()))% \(f.string(from: Date(timeIntervalSince1970: bp.at)))"
        } else if samples.count < 2 {
            caption += " · collecting…"
        } else {
            caption += " · no usage yet"
        }

        if historyExpanded {
            let item = NSMenuItem(title: caption, action: nil, keyEquivalent: "")
            item.view = HistoryChartView(caption: caption, days: days, colorFor: { [weak self] in self?.color(for: $0) ?? .gray },
                                         onToggle: { [weak self] in self?.toggleHistory() })
            menu.addItem(item)   // stays enabled so the view receives clicks
        } else {
            let item = action("\(caption)  ›", #selector(toggleHistoryAction))
            item.attributedTitle = NSAttributedString(
                string: "\(caption)  ›",
                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
            menu.addItem(item)
        }
    }

    @objc private func toggleHistoryAction() { toggleHistory() }

    /// Flip the setting and re‑open the menu so it feels like an in‑place expand.
    private func toggleHistory() {
        historyExpanded.toggle()
        menu.cancelTracking()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.rebuildMenu()
            self?.statusItem.button?.performClick(nil)
        }
    }

    private func header(_ text: String) -> NSMenuItem {
        let i = disabled(text)
        i.attributedTitle = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .bold),
                         .foregroundColor: NSColor.secondaryLabelColor])
        return i
    }

    private func errorItem(_ text: String) -> NSMenuItem {
        let i = disabled("⚠︎ \(text)")
        i.attributedTitle = NSAttributedString(
            string: "⚠︎ \(text)",
            attributes: [.foregroundColor: Self.mutedRed, .font: NSFont.menuFont(ofSize: 12)])
        return i
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func action(_ title: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        return i
    }

    private func relative(_ d: Date) -> String {
        let s = max(0, Int(d.timeIntervalSinceNow))
        let dd = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if dd > 0 { return "in \(dd)d \(h)h" }
        if h > 0 { return "in \(h)h \(m)m" }
        return "in \(m)m"
    }

    private func absolute(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = Calendar.current.isDateInToday(d) ? "'today' HH:mm" : "EEE d MMM, HH:mm"
        return f.string(from: d)
    }

    // MARK: - Actions

    @objc private func openClaudeUsage() {
        NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!)
    }

    @objc private func openChatGPTUsage() {
        NSWorkspace.shared.open(URL(string: "https://chatgpt.com/codex/settings/usage")!)
    }

    @objc private func toggleLogin() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            claudeError = "Launch at login: \(error.localizedDescription)"
        }
        rebuildMenu()
    }

    // MARK: - NSMenuDelegate

    /// Rebuild (fresh countdowns) right before the menu appears, never while it's open.
    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
        menuIsOpen = true
        if let t = lastUpdated, Date().timeIntervalSince(t) > 60 { refresh() }
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        if menuNeedsRebuild { rebuildMenu() }
    }
}

/// One usage window inside the menu: title + percent, a progress bar that
/// fills left‑to‑right as the quota is consumed, and the reset time below.
final class UsageRowView: NSView {
    private let percent: Double
    private let barColor: NSColor
    private let titleLabel = NSTextField(labelWithString: "")
    private let pctLabel = NSTextField(labelWithString: "")
    private let subLabel = NSTextField(labelWithString: "")
    private let paceLabel = NSTextField(labelWithString: "")
    private let barH: CGFloat = 6, inset: CGFloat = 14
    private var barY: CGFloat = 10

    init(title: String, percent: Double, subtitle: String, pace: (String, NSColor) = ("", .clear),
         color: NSColor, paceColor: NSColor = .secondaryLabelColor) {
        self.percent = min(max(percent, 0), 100)
        self.barColor = color
        let hasSub = !subtitle.isEmpty, hasPace = !pace.0.isEmpty
        let height: CGFloat = 44 + (hasSub ? 14 : 0) + (hasPace ? 14 : 0)
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: height))

        paceLabel.stringValue = pace.0
        paceLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        paceLabel.textColor = paceColor
        paceLabel.isHidden = !hasPace

        titleLabel.stringValue = title
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        pctLabel.stringValue = "\(Int(self.percent.rounded()))%"
        pctLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        pctLabel.textColor = color
        pctLabel.alignment = .right
        subLabel.stringValue = subtitle
        subLabel.font = NSFont.systemFont(ofSize: 11)
        subLabel.textColor = .secondaryLabelColor

        for l in [titleLabel, pctLabel, subLabel, paceLabel] { addSubview(l) }
        let w = bounds.width, h = bounds.height
        titleLabel.frame = NSRect(x: inset, y: h - 22, width: w - 2*inset - 50, height: 18)
        pctLabel.frame   = NSRect(x: w - inset - 50, y: h - 22, width: 50, height: 18)
        // Stack from the bottom: pace line, then reset line, then the bar.
        var y: CGFloat = 4
        if hasPace { paceLabel.frame = NSRect(x: inset, y: y, width: w - 2*inset, height: 15); y += 14 }
        if hasSub  { subLabel.frame  = NSRect(x: inset, y: y, width: w - 2*inset, height: 15); y += 14 }
        subLabel.isHidden = !hasSub
        barY = y + 6
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let trackW = bounds.width - 2*inset
        let y = barY
        let track = NSRect(x: inset, y: y, width: trackW, height: barH)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: barH/2, yRadius: barH/2).fill()
        let fillW = trackW * CGFloat(percent / 100)
        if fillW > 0 {
            barColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: inset, y: y, width: max(fillW, barH), height: barH),
                         xRadius: barH/2, yRadius: barH/2).fill()
        }
    }
}

/// Seven columns, one per day: height = that day's peak of the 5‑hour window,
/// colour by the usual thresholds. Clicking the caption collapses it again.
final class HistoryChartView: NSView {
    private let days: [(date: Date, peak: UsageHistory.DayPeak?)]
    private let colorFor: (Double) -> NSColor
    private let onToggle: () -> Void
    private let caption: String
    private let inset: CGFloat = 14

    init(caption: String, days: [(date: Date, peak: UsageHistory.DayPeak?)],
         colorFor: @escaping (Double) -> NSColor, onToggle: @escaping () -> Void) {
        self.caption = caption; self.days = days; self.colorFor = colorFor; self.onToggle = onToggle
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 96))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseUp(with event: NSEvent) { onToggle() }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let w = bounds.width
        // caption
        let cap = NSAttributedString(string: "\(caption)  ⌄",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        cap.draw(at: NSPoint(x: inset, y: bounds.height - 18))

        // chart area
        let chartTop = bounds.height - 24, chartBottom: CGFloat = 18, chartH = chartTop - chartBottom
        let gap: CGFloat = 5
        let colW = (w - 2*inset - gap * CGFloat(days.count - 1)) / CGFloat(days.count)
        let baseline = NSRect(x: inset, y: chartBottom - 1, width: w - 2*inset, height: 1)
        NSColor.separatorColor.setFill(); baseline.fill()

        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "EEE"
        let labelAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9),
                                                         .foregroundColor: NSColor.tertiaryLabelColor]
        for (i, day) in days.enumerated() {
            let x = inset + CGFloat(i) * (colW + gap)
            if let p = day.peak {
                let h = max(2, chartH * CGFloat(min(p.peak, 100) / 100))
                colorFor(p.peak).setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: chartBottom, width: colW, height: h),
                             xRadius: 2, yRadius: 2).fill()
            } else {
                // Day without a sample: faint placeholder so the chart reads as
                // "not collected yet" rather than "zero usage".
                NSColor.quaternaryLabelColor.setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: chartBottom, width: colW, height: chartH),
                             xRadius: 2, yRadius: 2).fill()
                let nd = NSAttributedString(string: "no\ndata", attributes: [
                    .font: NSFont.systemFont(ofSize: 8), .foregroundColor: NSColor.tertiaryLabelColor,
                    .paragraphStyle: { let p = NSMutableParagraphStyle(); p.alignment = .center; return p }()])
                let r = NSRect(x: x, y: chartBottom + chartH/2 - 10, width: colW, height: 20)
                nd.draw(in: r)
            }
            let label = NSAttributedString(string: f.string(from: day.date), attributes: labelAttrs)
            label.draw(at: NSPoint(x: x + (colW - label.size().width) / 2, y: 3))
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // no Dock icon
app.run()
