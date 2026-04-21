import AppKit
import Foundation
import Observation
import SwiftUI
import UserNotifications

enum AppAppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return String(localized: "跟随系统")
        case .light:  return String(localized: "浅色")
        case .dark:   return String(localized: "深色")
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

enum LaunchAtLoginError: LocalizedError {
    case cannotCreateLaunchAgentDir
    case cannotWriteLaunchAgent
    case cannotRemoveLaunchAgent

    var errorDescription: String? {
        switch self {
        case .cannotCreateLaunchAgentDir:
            return String(localized: "无法创建 LaunchAgents 目录。")
        case .cannotWriteLaunchAgent:
            return String(localized: "无法写入开机启动配置。")
        case .cannotRemoveLaunchAgent:
            return String(localized: "无法移除开机启动配置。")
        }
    }
}

enum MonitorError: LocalizedError {
    case invalidBaseURL
    case missingAuthToken
    case malformedJSON
    case badStatusCode(Int)
    case unexpectedResponse(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return String(localized: "Base URL 无效。")
        case .missingAuthToken:
            return String(localized: "Token 为空。")
        case .malformedJSON:
            return String(localized: "接口返回结构和当前解析不匹配。")
        case .badStatusCode(let code):
            return String(format: String(localized: "接口返回状态码 %lld。"), code)
        case .unexpectedResponse(let message):
            return message
        }
    }
}

struct QuotaMetric {
    let title: String
    let percentage: Double
    let summary: String
    let detail: String
    let resetAt: Date?
}

struct ToolUsageTotals {
    let networkSearchCount: Int
    let webReadCount: Int
    let zreadCount: Int

    var totalCount: Int {
        networkSearchCount + webReadCount + zreadCount
    }
}

struct UsageSnapshot {
    let fetchedAt: Date
    let fiveHour: QuotaMetric
    let weekly: QuotaMetric
    let totalTokens24h: Int
    let totalCalls24h: Int
    let modelSummaries: [ModelSummary]
    let toolTotals: ToolUsageTotals
    let planLevel: String?
    /// 24 hourly token counts (oldest → newest). Used by sparklines.
    let hourlyTokens: [Int]
    /// Sum of tokens for the 24h window immediately preceding the current one.
    /// `nil` when not available (e.g., first-run race or API error).
    let previousDayTokens: Int?

    var labelText: String {
        // Menu-bar shows the 5h window — that's what changes minute-to-minute and
        // is most actionable. Weekly trend lives one click away in the panel.
        String(format: String(localized: "GLM %lld%%"), Int(fiveHour.percentage.rounded()))
    }
}

struct APIEnvelope<T: Decodable>: Decodable {
    let code: Int?
    let msg: String?
    let data: T
    let success: Bool?
}

struct ModelUsageResponse: Decodable {
    let xTime: [String]
    let modelCallCount: [Int]
    let tokensUsage: [Int]
    let totalUsage: ModelUsageTotals
    let modelDataList: [ModelDataPoint]
    let modelSummaryList: [ModelSummary]
    let granularity: String?

    enum CodingKeys: String, CodingKey {
        case xTime = "x_time"
        case modelCallCount
        case tokensUsage
        case totalUsage
        case modelDataList
        case modelSummaryList
        case granularity
    }
}

struct ModelUsageTotals: Decodable {
    let totalModelCallCount: Int?
    let totalTokensUsage: Int?
    let modelSummaryList: [ModelSummary]?
}

struct ModelSummary: Decodable, Identifiable {
    let modelName: String
    let totalTokens: Int
    let sortOrder: Int?

    var id: String { modelName }
}

struct ModelDataPoint: Decodable {
    let modelName: String
    let sortOrder: Int?
    let tokensUsage: [Int]
    let totalTokens: Int?
}

struct ToolUsageResponse: Decodable {
    let xTime: [String]
    let networkSearchCount: [Int]
    let webReadMcpCount: [Int]
    let zreadMcpCount: [Int]
    let totalUsage: ToolUsageTotalUsage

    enum CodingKeys: String, CodingKey {
        case xTime = "x_time"
        case networkSearchCount
        case webReadMcpCount
        case zreadMcpCount
        case totalUsage
    }
}

struct ToolUsageTotalUsage: Decodable {
    let totalNetworkSearchCount: Int?
    let totalWebReadMcpCount: Int?
    let totalZreadMcpCount: Int?
}

struct QuotaLimitResponse: Decodable {
    let limits: [QuotaLimitItem]
    let level: String?
}

struct QuotaLimitItem: Decodable {
    let type: String
    let unit: Int?
    let number: Int?
    let percentage: Double?
    let nextResetTime: Double?
    let usage: Int?
    let currentValue: Double?
    let remaining: Double?
}

struct HourlyQueryWindow {
    let startText: String
    let endText: String
}

@MainActor
final class MonitorViewModel: ObservableObject {
    static let defaultsDomain = "com.jingcc.glm-pulse"
    static let chinaBaseURL   = "https://open.bigmodel.cn/api/anthropic"
    static let globalBaseURL  = "https://api.z.ai/api/anthropic"
    static let defaultBaseURL = globalBaseURL
    static let defaultRefreshSeconds = 60.0
    static let supportedTimezones = [
        "Asia/Tokyo",
        "Asia/Shanghai",
        "Asia/Hong_Kong",
        "Asia/Singapore",
        "America/Los_Angeles",
        "America/New_York",
        "Europe/London",
        "Europe/Berlin",
    ]

    @Published var baseURL: String
    @Published var authToken: String
    @Published var refreshSeconds: Double
    @Published var autoRefresh: Bool
    @Published var launchAtLogin: Bool
    @Published var windowTimezoneID: String
    @Published var appearanceMode: AppAppearanceMode
    @Published var notificationsEnabled: Bool
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var lastError: String?
    @Published var settingsError: String?
    @Published private(set) var secondsUntilRefresh: Int
    @Published private(set) var isRefreshing = false

    private let defaults: UserDefaults
    private var timer: Timer?
    private var activeRefreshTask: Task<Void, Never>?

    /// Per-reset-window dedup for threshold notifications.
    private var notified80ForResetAt: Date?
    private var notified95ForResetAt: Date?

    /// Weak singleton so AppDelegate can reach the live view model for
    /// first-run windows without plumbing it through Scene environments.
    static weak var shared: MonitorViewModel?

    init() {
        defaults = UserDefaults(suiteName: Self.defaultsDomain) ?? .standard

        let storedTimezone = defaults.string(forKey: "windowTimezoneID")
        let currentTimezone = TimeZone.current.identifier
        let resolvedTimezone = Self.supportedTimezones.contains(storedTimezone ?? "")
            ? storedTimezone!
            : (Self.supportedTimezones.contains(currentTimezone) ? currentTimezone : "Asia/Tokyo")

        baseURL = defaults.string(forKey: "baseURL") ?? Self.defaultBaseURL
        authToken = defaults.string(forKey: "authToken")
            ?? ProcessInfo.processInfo.environment["ANTHROPIC_AUTH_TOKEN"]
            ?? ""
        let storedRefresh = defaults.object(forKey: "refreshSeconds") as? Double
        refreshSeconds = max(10, storedRefresh ?? Self.defaultRefreshSeconds)
        autoRefresh = defaults.object(forKey: "autoRefresh") as? Bool ?? true
        launchAtLogin = defaults.object(forKey: "launchAtLogin") as? Bool ?? false
        windowTimezoneID = resolvedTimezone
        appearanceMode = AppAppearanceMode(rawValue: defaults.string(forKey: "appearanceMode") ?? "system") ?? .system
        notificationsEnabled = defaults.object(forKey: "notificationsEnabled") as? Bool ?? true
        secondsUntilRefresh = Int(max(10, storedRefresh ?? Self.defaultRefreshSeconds))

        MonitorViewModel.shared = self
        applyAppearance()
        startTimer()
        refreshNow()
    }

    var nextRefreshText: String {
        autoRefresh
            ? String(format: String(localized: "%lld s 后刷新"), secondsUntilRefresh)
            : String(localized: "已关闭自动刷新")
    }

    func refreshNow() {
        activeRefreshTask?.cancel()
        activeRefreshTask = nil

        let trimmedToken = authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedToken.isEmpty {
            lastError = MonitorError.missingAuthToken.localizedDescription
            snapshot = nil
            isRefreshing = false
            resetCountdown()
            return
        }

        isRefreshing = true
        settingsError = nil

        let requestBaseURL = baseURL
        let requestToken = trimmedToken
        let requestTimezoneID = windowTimezoneID

        activeRefreshTask = Task { [weak self] in
            defer {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isRefreshing = false
                    self.resetCountdown()
                }
            }
            do {
                let snapshot = try await Self.fetchSnapshot(
                    baseURL: requestBaseURL,
                    token: requestToken,
                    windowTimezoneID: requestTimezoneID
                )
                if Task.isCancelled { return }
                await MainActor.run {
                    self?.snapshot = snapshot
                    self?.lastError = nil
                    self?.checkQuotaThresholds(snapshot)
                }
            } catch {
                if Task.isCancelled { return }
                if error is CancellationError { return }
                if let urlError = error as? URLError, urlError.code == .cancelled { return }
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await MainActor.run { self?.lastError = message }
            }
        }
    }

    func applySettings(refresh: Bool) {
        saveSettings()
        applyAppearance()

        do {
            if launchAtLogin {
                try writeLaunchAgent()
            } else {
                try removeLaunchAgent()
            }
            settingsError = nil
        } catch {
            settingsError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }

        if refresh {
            refreshNow()
        } else {
            resetCountdown()
        }
    }

    func resetRecommended() {
        baseURL = Self.defaultBaseURL
        refreshSeconds = Self.defaultRefreshSeconds
        autoRefresh = true
        let currentTimezone = TimeZone.current.identifier
        windowTimezoneID = Self.supportedTimezones.contains(currentTimezone) ? currentTimezone : "Asia/Tokyo"
        appearanceMode = .system
        notificationsEnabled = true
    }

    var hasToken: Bool {
        !authToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Build a markdown snapshot of the current usage for clipboard sharing.
    func markdownSnapshot() -> String? {
        guard let snap = snapshot else { return nil }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        df.timeZone = TimeZone(identifier: windowTimezoneID) ?? .current
        let header = String(format: NSLocalizedString("copy.header", comment: ""), df.string(from: snap.fetchedAt))
        var lines: [String] = ["**\(header)**"]
        lines.append("- " + String(format: NSLocalizedString("copy.weekly", comment: ""), Int(snap.weekly.percentage.rounded())))
        lines.append("- " + String(format: NSLocalizedString("copy.fiveHour", comment: ""), Int(snap.fiveHour.percentage.rounded())))
        lines.append("- " + String(format: NSLocalizedString("copy.tokens24h", comment: ""), MonitorViewModel.formatTokenCount(snap.totalTokens24h)))
        lines.append("- " + String(format: NSLocalizedString("copy.calls24h", comment: ""), snap.totalCalls24h))
        if let top = snap.modelSummaries.first {
            lines.append("- " + String(format: NSLocalizedString("copy.topModel", comment: ""),
                                        top.modelName,
                                        MonitorViewModel.formatTokenCount(top.totalTokens)))
        }
        if let plan = snap.planLevel {
            lines.append("- " + String(format: NSLocalizedString("copy.plan", comment: ""), plan.uppercased()))
        }
        return lines.joined(separator: "\n")
    }

    /// Copy markdown snapshot to clipboard. Returns true if something was copied.
    @discardableResult
    func copySnapshotToClipboard() -> Bool {
        guard let md = markdownSnapshot() else { return false }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(md, forType: .string)
        return true
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func tick() {
        guard autoRefresh else {
            secondsUntilRefresh = 0
            return
        }

        if secondsUntilRefresh > 0 {
            secondsUntilRefresh -= 1
            return
        }

        refreshNow()
    }

    private func resetCountdown() {
        secondsUntilRefresh = autoRefresh ? Int(max(10, refreshSeconds.rounded())) : 0
    }

    private func applyAppearance() {
        NSApp.appearance = appearanceMode.nsAppearance
    }

    private func saveSettings() {
        defaults.set(baseURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "baseURL")
        defaults.set(authToken.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "authToken")
        defaults.set(max(10, refreshSeconds.rounded()), forKey: "refreshSeconds")
        defaults.set(autoRefresh, forKey: "autoRefresh")
        defaults.set(launchAtLogin, forKey: "launchAtLogin")
        defaults.set(windowTimezoneID, forKey: "windowTimezoneID")
        defaults.set(appearanceMode.rawValue, forKey: "appearanceMode")
        defaults.set(notificationsEnabled, forKey: "notificationsEnabled")
    }

    // MARK: - Threshold notifications

    /// Call after each successful snapshot fetch. Fires macOS notifications
    /// once per reset window at 80 % and 95 %, with per-window dedup.
    func checkQuotaThresholds(_ snapshot: UsageSnapshot) {
        guard notificationsEnabled else { return }
        let pct = snapshot.weekly.percentage
        let resetAt = snapshot.weekly.resetAt

        // If the reset window rolled over, clear dedup flags.
        if notified80ForResetAt != resetAt { notified80ForResetAt = nil }
        if notified95ForResetAt != resetAt { notified95ForResetAt = nil }

        if pct >= 95, notified95ForResetAt != resetAt {
            postThresholdNotification(
                bodyKey: "notify.quota.95.body",
                pct: Int((100 - pct).rounded())
            )
            notified95ForResetAt = resetAt
            notified80ForResetAt = resetAt // 95 implies 80
        } else if pct >= 80, notified80ForResetAt != resetAt {
            postThresholdNotification(
                bodyKey: "notify.quota.80.body",
                pct: Int(pct.rounded())
            )
            notified80ForResetAt = resetAt
        }
    }

    private func postThresholdNotification(bodyKey: String, pct: Int) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            guard granted, self != nil else { return }
            let content = UNMutableNotificationContent()
            content.title = NSLocalizedString("notify.quota.title", comment: "")
            content.body = String(format: NSLocalizedString(bodyKey, comment: ""), pct)
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "glm.quota.\(bodyKey).\(Int(Date().timeIntervalSince1970))",
                content: content,
                trigger: nil
            )
            center.add(request, withCompletionHandler: nil)
        }
    }

    private func writeLaunchAgent() throws {
        let launchAgentsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("LaunchAgents")

        do {
            try FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)
        } catch {
            throw LaunchAtLoginError.cannotCreateLaunchAgentDir
        }

        let plistURL = launchAgentsDir.appendingPathComponent("local.jing.glm-token-monitor.plist")
        let executableTarget = Bundle.main.bundleURL.pathExtension == "app"
            ? Bundle.main.bundleURL.path
            : Bundle.main.executableURL?.path ?? Bundle.main.bundleURL.path

        let plist: [String: Any] = [
            "Label": "local.jing.glm-token-monitor",
            "ProgramArguments": ["/usr/bin/open", "-gj", executableTarget],
            "RunAtLoad": true,
            "KeepAlive": false,
        ]

        do {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
        } catch {
            throw LaunchAtLoginError.cannotWriteLaunchAgent
        }
    }

    private func removeLaunchAgent() throws {
        let plistURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("LaunchAgents")
            .appendingPathComponent("local.jing.glm-token-monitor.plist")

        guard FileManager.default.fileExists(atPath: plistURL.path) else { return }

        do {
            try FileManager.default.removeItem(at: plistURL)
        } catch {
            throw LaunchAtLoginError.cannotRemoveLaunchAgent
        }
    }

    static func fetchSnapshot(
        baseURL: String,
        token: String,
        windowTimezoneID: String
    ) async throws -> UsageSnapshot {
        let monitorBaseURL = try monitorBaseDomain(baseURL: baseURL)
        let queryWindow = hourlyWindow(now: Date(), timeZoneID: windowTimezoneID)
        let prevWindow = previousHourlyWindow(now: Date(), timeZoneID: windowTimezoneID)

        async let modelUsage: ModelUsageResponse = fetchJSON(
            url: "\(monitorBaseURL)/api/monitor/usage/model-usage?startTime=\(queryWindow.startText.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? queryWindow.startText)&endTime=\(queryWindow.endText.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? queryWindow.endText)",
            token: token
        )

        async let previousModelUsage: ModelUsageResponse? = try? fetchJSON(
            url: "\(monitorBaseURL)/api/monitor/usage/model-usage?startTime=\(prevWindow.startText.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? prevWindow.startText)&endTime=\(prevWindow.endText.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? prevWindow.endText)",
            token: token
        )

        async let toolUsage: ToolUsageResponse = fetchJSON(
            url: "\(monitorBaseURL)/api/monitor/usage/tool-usage?startTime=\(queryWindow.startText.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? queryWindow.startText)&endTime=\(queryWindow.endText.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? queryWindow.endText)",
            token: token
        )

        async let quotaLimit: QuotaLimitResponse = fetchJSON(
            url: "\(monitorBaseURL)/api/monitor/usage/quota/limit",
            token: token
        )

        let model = try await modelUsage
        let tool = try await toolUsage
        let quota = try await quotaLimit
        let previousModel = await previousModelUsage

        let totalTokens = model.totalUsage.totalTokensUsage ?? model.tokensUsage.reduce(0, +)
        let totalCalls = model.totalUsage.totalModelCallCount ?? model.modelCallCount.reduce(0, +)
        let lastFiveHourTokens = model.tokensUsage.suffix(5).reduce(0, +)

        let sortedTokenLimits = quota.limits
            .filter { $0.type == "TOKENS_LIMIT" }
            .sorted { ($0.nextResetTime ?? 0) < ($1.nextResetTime ?? 0) }

        let fiveHourLimit = sortedTokenLimits.first
        let weeklyLimit = sortedTokenLimits.dropFirst().first ?? sortedTokenLimits.first

        let fiveHourMetric = QuotaMetric(
            title: String(localized: "5h 配额"),
            percentage: fiveHourLimit?.percentage ?? 0,
            summary: formatTokenCount(lastFiveHourTokens),
            detail: String(localized: "近 5 小时 tokens"),
            resetAt: dateFromMilliseconds(fiveHourLimit?.nextResetTime)
        )

        let weeklyMetric = QuotaMetric(
            title: String(localized: "Weekly 配额"),
            percentage: weeklyLimit?.percentage ?? 0,
            summary: quota.level?.uppercased() ?? "PRO",
            detail: String(format: String(localized: "最近 24h %@ / %lld calls"),
                           formatTokenCount(totalTokens), totalCalls),
            resetAt: dateFromMilliseconds(weeklyLimit?.nextResetTime)
        )

        let preferredModelSummaries = model.totalUsage.modelSummaryList?.isEmpty == false
            ? model.totalUsage.modelSummaryList ?? []
            : model.modelSummaryList
        let modelSummaries = preferredModelSummaries
            .sorted { ($0.sortOrder ?? 999) < ($1.sortOrder ?? 999) }

        let toolTotals = ToolUsageTotals(
            networkSearchCount: tool.totalUsage.totalNetworkSearchCount ?? 0,
            webReadCount: tool.totalUsage.totalWebReadMcpCount ?? 0,
            zreadCount: tool.totalUsage.totalZreadMcpCount ?? 0
        )

        let previousDayTokens: Int? = previousModel.map {
            $0.totalUsage.totalTokensUsage ?? $0.tokensUsage.reduce(0, +)
        }

        return UsageSnapshot(
            fetchedAt: Date(),
            fiveHour: fiveHourMetric,
            weekly: weeklyMetric,
            totalTokens24h: totalTokens,
            totalCalls24h: totalCalls,
            modelSummaries: modelSummaries,
            toolTotals: toolTotals,
            planLevel: quota.level,
            hourlyTokens: model.tokensUsage,
            previousDayTokens: previousDayTokens
        )
    }

    private static func fetchJSON<T: Decodable>(url: String, token: String) async throws -> T {
        guard let requestURL = URL(string: url) else {
            throw MonitorError.invalidBaseURL
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en", forHTTPHeaderField: "Accept-Language")
        request.setValue(token, forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, !(200 ... 299).contains(httpResponse.statusCode) {
            throw MonitorError.badStatusCode(httpResponse.statusCode)
        }

        do {
            let envelope = try JSONDecoder().decode(APIEnvelope<T>.self, from: data)
            return envelope.data
        } catch {
            throw MonitorError.malformedJSON
        }
    }

    private static func monitorBaseDomain(baseURL: String) throws -> String {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme, let host = url.host else {
            throw MonitorError.invalidBaseURL
        }
        return "\(scheme)://\(host)"
    }

    private static func hourlyWindow(now: Date, timeZoneID: String) -> HourlyQueryWindow {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneID) ?? .current

        let currentHourStart = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        let startDate = calendar.date(byAdding: .hour, value: -24, to: currentHourStart) ?? now
        let endDate = calendar.date(byAdding: .second, value: 3599, to: currentHourStart) ?? now

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        return HourlyQueryWindow(
            startText: formatter.string(from: startDate),
            endText: formatter.string(from: endDate)
        )
    }

    /// The 24h window immediately preceding the current one. Used for the
    /// "vs 昨日" comparison on the sparkline card.
    private static func previousHourlyWindow(now: Date, timeZoneID: String) -> HourlyQueryWindow {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneID) ?? .current

        let currentHourStart = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        let startDate = calendar.date(byAdding: .hour, value: -48, to: currentHourStart) ?? now
        let endDate = calendar.date(byAdding: .second, value: -1,
                                    to: calendar.date(byAdding: .hour, value: -24, to: currentHourStart) ?? now) ?? now

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        return HourlyQueryWindow(
            startText: formatter.string(from: startDate),
            endText: formatter.string(from: endDate)
        )
    }

    private static func dateFromMilliseconds(_ value: Double?) -> Date? {
        guard let value else { return nil }
        return Date(timeIntervalSince1970: value / 1000)
    }

    static func formatTokenCount(_ value: Int) -> String {
        switch value {
        case 1_000_000...:
            return String(format: "%.2fM", Double(value) / 1_000_000)
        case 1_000...:
            return String(format: "%.1fK", Double(value) / 1_000)
        default:
            return "\(value)"
        }
    }
}
