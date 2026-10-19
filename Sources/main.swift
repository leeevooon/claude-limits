import Cocoa

// Окно лимита из ответа /api/oauth/usage: utilization — израсходованный процент.
struct Window {
    let id: String
    let usedPercent: Double
    let resetsAt: Date?
    var remaining: Int { Int(max(0, min(100, 100 - usedPercent)).rounded(.down)) }
    var title: String? = nil
    var name: String {
        if let title = title { return title }
        switch id {
        case "five_hour": return "5 часов"
        case "seven_day": return "Неделя"
        case "seven_day_opus": return "Неделя · Opus"
        case "seven_day_sonnet": return "Неделя · Sonnet"
        case "seven_day_oauth_apps": return "Неделя · приложения"
        default: return "Прочий лимит (\(id))"
        }
    }
    var order: Int {
        if title != nil { return 50 }
        return ["five_hour", "seven_day", "seven_day_sonnet", "seven_day_opus", "seven_day_oauth_apps"].firstIndex(of: id) ?? 99
    }
}
struct Snapshot {
    let windows: [Window]
    let plan: String?
    var remaining: Int? { windows.map { $0.remaining }.min() }
}

func parseDate(_ value: Any?) -> Date? {
    guard var text = value as? String else { return nil }
    let formatter = ISO8601DateFormatter()
    // Сервер отдаёт микросекунды, ISO8601DateFormatter понимает только миллисекунды.
    if let dot = text.firstIndex(of: "."), let zone = text[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
        text.removeSubrange(dot..<zone)
    }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: text)
}
func parseUsage(_ data: Data, plan: String?) throws -> Snapshot {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw FetchError.format }
    var windows = object.compactMap { key, value -> Window? in
        guard key != "extra_usage", let window = value as? [String: Any], let used = window["utilization"] as? Double else { return nil }
        return Window(id: key, usedPercent: used, resetsAt: parseDate(window["resets_at"]))
    }
    // Недельные окна по моделям: limits[] с scope.model.display_name, как в /usage Claude Code.
    for case let limit as [String: Any] in object["limits"] as? [Any] ?? [] {
        guard let model = (limit["scope"] as? [String: Any])?["model"] as? [String: Any],
              let label = model["display_name"] as? String, let used = limit["percent"] as? Double else { continue }
        let reset = (limit["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? parseDate(limit["resets_at"])
        windows.append(Window(id: "model:" + label, usedPercent: used, resetsAt: reset, title: "Неделя · " + label))
    }
    return Snapshot(windows: windows.sorted { ($0.order, $0.id) < ($1.order, $1.id) }, plan: plan)
}

enum FetchError: Error { case noCredentials, expired, network, format }

// Токен Claude Code. Читаем через /usr/bin/security: Claude Code сам создаёт этот элемент,
// поэтому macOS не спрашивает пароль. Токен никуда, кроме api.anthropic.com, не уходит.
func credentials() throws -> (token: String, plan: String?) {
    var raw: Data?
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    if (try? process.run()) != nil {
        raw = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 { raw = nil }
    }
    if raw == nil {
        raw = FileManager.default.contents(atPath: FileManager.default.homeDirectoryForCurrentUser.path + "/.claude/.credentials.json")
    }
    guard let data = raw,
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let oauth = object["claudeAiOauth"] as? [String: Any],
          let token = oauth["accessToken"] as? String, !token.isEmpty else { throw FetchError.noCredentials }
    if let expires = oauth["expiresAt"] as? Double, expires / 1000 < Date().timeIntervalSince1970 { throw FetchError.expired }
    return (token, oauth["subscriptionType"] as? String)
}

func fetch() throws -> Snapshot {
    let (token, plan) = try credentials()
    var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!, timeoutInterval: 20)
    request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
    request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    request.setValue("claude-limits-menu/1.0", forHTTPHeaderField: "User-Agent")
    var result: Result<Data, FetchError> = .failure(.network)
    let done = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: request) { data, response, _ in
        defer { done.signal() }
        guard let status = (response as? HTTPURLResponse)?.statusCode, let data = data else { return }
        if status == 401 || status == 403 { result = .failure(.expired) }
        else if status == 200 { result = .success(data) }
    }.resume()
    done.wait()
    return try parseUsage(result.get(), plan: plan)
}

enum QuotaLevel {
    case healthy, medium, low
    init(_ percent: Int) { self = percent > 60 ? .healthy : (percent >= 25 ? .medium : .low) }
    var color: NSColor {
        switch self {
        case .healthy: return NSColor(calibratedRed: 0.05, green: 0.78, blue: 0.72, alpha: 1)
        case .medium: return NSColor(calibratedRed: 0.96, green: 0.69, blue: 0.08, alpha: 1)
        case .low: return NSColor(calibratedRed: 0.95, green: 0.25, blue: 0.27, alpha: 1)
        }
    }
}
func statusRing(_ percent: Int?) -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
        let track = NSBezierPath(ovalIn: NSRect(x: 3, y: 3, width: 12, height: 12))
        track.lineWidth = 2.5
        NSColor.secondaryLabelColor.withAlphaComponent(0.35).setStroke(); track.stroke()
        if let percent = percent, percent > 0 {
            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: 9, y: 9), radius: 6, startAngle: 90, endAngle: 90 + 360 * Double(percent) / 100, clockwise: false)
            arc.lineWidth = 2.5; arc.lineCapStyle = .round
            QuotaLevel(percent).color.setStroke(); arc.stroke()
        }
        return true
    }
    image.isTemplate = false
    return image
}
final class QuotaBar: NSView {
    let percent: Int
    init(percent: Int) {
        self.percent = percent
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 23))
        setAccessibilityElement(true)
        setAccessibilityLabel("Осталось \(percent)% лимита")
    }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        let color = QuotaLevel(percent).color
        for segment in 0..<10 {
            let rect = NSRect(x: 20 + CGFloat(segment) * 21, y: 6, width: 17, height: 11)
            let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
            color.withAlphaComponent(0.18).setFill(); path.fill()
            let fraction = max(0, min(1, CGFloat(percent) / 10 - CGFloat(segment)))
            if fraction > 0 {
                NSGraphicsContext.saveGraphicsState()
                NSRect(x: rect.minX, y: rect.minY, width: rect.width * fraction, height: rect.height).clip()
                color.setFill(); path.fill()
                NSGraphicsContext.restoreGraphicsState()
            }
        }
    }
}
func countdown(_ seconds: Int) -> String {
    let days = seconds / 86400, hours = (seconds % 86400) / 3600, minutes = (seconds % 3600) / 60
    return days > 0 ? "Через \(days) дн. \(hours) ч. \(minutes) мин." : "Через \(hours) ч. \(minutes) мин."
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var status: NSStatusItem!
    let menu = NSMenu()
    var snapshot: Snapshot?
    var updated: Date?
    var error: String?
    var busy = false
    var timer: Timer?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        status.button?.title = " …"
        status.button?.image = statusRing(nil)
        status.button?.imagePosition = .imageLeading
        menu.delegate = self
        status.menu = menu
        NotificationCenter.default.addObserver(self, selector: #selector(systemTimeChanged), name: NSNotification.Name.NSSystemTimeZoneDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(systemTimeChanged), name: NSNotification.Name.NSSystemClockDidChange, object: nil)
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 180, repeats: true) { [weak self] _ in self?.refresh() }
        timer?.tolerance = 15
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wake), name: NSWorkspace.didWakeNotification, object: nil)
    }
    @objc func wake() { refresh() }
    @objc func systemTimeChanged() {
        NSTimeZone.resetSystemTimeZone()
        rebuild()
    }
    func menuWillOpen(_ menu: NSMenu) { rebuild(); if Date().timeIntervalSince(updated ?? .distantPast) > 60 { refresh() } }
    func label(_ title: String) { let item = NSMenuItem(title: title, action: nil, keyEquivalent: ""); item.isEnabled = false; menu.addItem(item) }
    func rebuild() {
        menu.removeAllItems()
        label("Claude · остаток лимитов" + (snapshot?.plan.map { " (\($0.capitalized))" } ?? ""))
        menu.addItem(.separator())
        if let snapshot = snapshot {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "ru_RU"); formatter.timeZone = .autoupdatingCurrent; formatter.dateFormat = "d MMM, HH:mm (zzz)"
            for window in snapshot.windows {
                label("\(window.name): осталось \(window.remaining)%")
                let bar = NSMenuItem()
                bar.view = QuotaBar(percent: window.remaining)
                menu.addItem(bar)
                if let reset = window.resetsAt {
                    label("Сброс: " + formatter.string(from: reset))
                    let seconds = max(0, Int(reset.timeIntervalSinceNow))
                    label(seconds == 0 ? "Ожидаем обновления лимита" : countdown(seconds))
                } else { label("Лимит не расходуется, сброса нет") }
            }
            if snapshot.remaining == nil { label("Сервер не вернул окна лимитов") }
        }
        if let error = error { label(error) }
        menu.addItem(.separator())
        let usage = NSMenuItem(title: "Открыть claude.ai/settings/usage", action: #selector(openUsage), keyEquivalent: "")
        usage.target = self; menu.addItem(usage)
        let age = updated.map { " · \(max(0, Int(Date().timeIntervalSince($0) / 60))) мин. назад" } ?? ""
        let refreshItem = NSMenuItem(title: busy ? "Обновление…" : "Обновить" + age, action: #selector(refresh), keyEquivalent: "r")
        refreshItem.target = self; refreshItem.isEnabled = !busy; menu.addItem(refreshItem)
        let quit = NSMenuItem(title: "Завершить Claude Limits", action: #selector(quitApp), keyEquivalent: "q"); quit.target = self; menu.addItem(quit)
    }
    @objc func openUsage() { NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!) }
    @objc func quitApp() { NSApp.terminate(nil) }
    @objc func refresh() {
        guard !busy else { return }; busy = true
        rebuild()
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try fetch() }
            DispatchQueue.main.async {
                self.busy = false
                switch result {
                case .success(let data):
                    self.snapshot = data; self.updated = Date(); self.error = nil
                    self.status.button?.title = data.remaining.map { " \($0)%" } ?? " —"
                    self.status.button?.image = statusRing(data.remaining)
                    self.status.button?.toolTip = "Claude: осталось \(data.remaining.map(String.init) ?? "—")%. Нажмите для подробностей."
                case .failure(let problem):
                    switch problem as? FetchError {
                    case .noCredentials: self.error = "Войдите в Claude Code: claude → /login"
                    case .expired: self.error = "Вход устарел. Запустите Claude Code — он обновит токен"
                    case .format: self.error = "Сервер ответил в неизвестном формате"
                    default: self.error = "Нет связи с api.anthropic.com"
                    }
                    self.status.button?.title = " !"
                    self.status.button?.image = statusRing(nil)
                    self.status.button?.toolTip = "\(self.error!) Последние данные доступны в меню."
                }
                self.rebuild()
            }
        }
    }
}

if CommandLine.arguments.contains("--self-test") {
    precondition(QuotaLevel(100) == .healthy && QuotaLevel(61) == .healthy)
    precondition(QuotaLevel(60) == .medium && QuotaLevel(50) == .medium && QuotaLevel(25) == .medium)
    precondition(QuotaLevel(24) == .low && QuotaLevel(0) == .low)
    let sample = """
    {"five_hour":{"utilization":37.0,"resets_at":"2026-10-19T15:00:00.412345+00:00"},
     "seven_day":{"utilization":81.5,"resets_at":"2026-10-23T09:00:00+00:00"},
     "seven_day_opus":{"utilization":0.0,"resets_at":null},"seven_day_oauth_apps":null,
     "extra_usage":{"is_enabled":false,"utilization":null},"iguana_necktie":{"utilization":5.0,"resets_at":null},
     "limits":[{"scope":{"model":{"display_name":"Fable"}},"percent":40.0,"resets_at":1792000000},{"scope":{}}]}
    """
    let parsed = try! parseUsage(Data(sample.utf8), plan: "max")
    precondition(parsed.windows.map { $0.id } == ["five_hour", "seven_day", "seven_day_opus", "model:Fable", "iguana_necktie"])
    precondition(parsed.windows.map { $0.name } == ["5 часов", "Неделя", "Неделя · Opus", "Неделя · Fable", "Прочий лимит (iguana_necktie)"])
    precondition(parsed.windows.map { $0.remaining } == [63, 18, 100, 60, 95] && parsed.remaining == 18)
    precondition(parsed.windows[0].resetsAt == parseDate("2026-10-19T15:00:00Z") && parsed.windows[2].resetsAt == nil)
    print("Self-test OK: colors 61–100 teal, 25–60 yellow, 0–24 red; usage JSON parsed")
} else if CommandLine.arguments.contains("--check") {
    do {
        let snapshot = try fetch()
        print("Check OK; plan: \(snapshot.plan ?? "?"); " + snapshot.windows.map { "\($0.id)=\($0.remaining)%" }.joined(separator: ", "))
    } catch { print("Check failed: \(error)"); exit(1) }
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
