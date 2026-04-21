import AppKit
import SwiftUI

// MARK: - Design tokens

private enum GLMChrome {
    static let blue   = Color(red: 0.17, green: 0.44, blue: 0.94)
    static let teal   = Color(red: 0.06, green: 0.73, blue: 0.68)
    static let gold   = Color(red: 0.83, green: 0.70, blue: 0.42)
    static let red    = Color(red: 0.89, green: 0.39, blue: 0.32)
    static let orange = Color(red: 0.95, green: 0.56, blue: 0.18)
    static let cardCorner     = CGFloat(18)
    static let glassStroke    = Color.white.opacity(0.13)
    static let glassHighlight = Color.white.opacity(0.09)
    static let mutedFill      = Color.white.opacity(0.03)
    static let deepTint       = Color.black.opacity(0.18)

    static func quotaColor(_ pct: Double) -> Color {
        pct >= 85 ? red : pct >= 65 ? orange : teal
    }
}

// MARK: - Menu-bar helpers

extension Notification.Name {
    /// Fired by AppDelegate's right-click context menu. Listened to by the
    /// MenuBarExtra label, which has access to @Environment(\.openWindow).
    static let openSettingsRequested = Notification.Name("GLMOpenSettingsRequested")
}

/// Hide the MenuBarExtra popover. Used when we open a regular window (Settings) from the panel —
/// without this, the popover keeps floating on top of whatever the user is doing.
@MainActor
func dismissMenuBarPanel() {
    // Known class substrings used by SwiftUI's MenuBarExtra(.window) across macOS versions:
    // MenuBarExtraPanel / MenuBarExtraWindow / NSStatusBarWindow / NSPopoverWindow.
    for window in NSApp.windows where window.isVisible {
        let cls = String(describing: type(of: window))
        if cls.contains("MenuBarExtra") ||
            cls.contains("StatusBar") ||
            cls.contains("Popover") {
            window.orderOut(nil)
        }
    }
}

// MARK: - Menu-bar label

struct StatusLabelView: View {
    let snapshot: UsageSnapshot?
    let lastError: String?
    let isRefreshing: Bool
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
            Text(labelText)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        // Bridge from AppDelegate's right-click NSMenu (which has no SwiftUI env).
        .onReceive(NotificationCenter.default.publisher(for: .openSettingsRequested)) { _ in
            dismissMenuBarPanel()
            openWindow(id: "settings")
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private var dotColor: Color {
        if lastError != nil { return GLMChrome.red }
        if isRefreshing     { return GLMChrome.gold }
        // Color tracks whatever number we're showing (5h), so dot + number agree.
        if let p = snapshot?.fiveHour.percentage { return GLMChrome.quotaColor(p) }
        return GLMChrome.teal
    }

    private var labelText: String {
        if isRefreshing     { return String(localized: "GLM …") }
        if lastError != nil { return String(localized: "GLM !") }
        return snapshot?.labelText ?? String(localized: "GLM --")
    }
}

// MARK: - Menu-bar panel

struct StatusPanelView: View {
    @ObservedObject var viewModel: MonitorViewModel
    @Environment(\.openWindow) private var openWindow
    @State private var copyToast: Bool = false

    var body: some View {
        ZStack(alignment: .top) {
            PremiumBackdrop()
            if !viewModel.hasToken {
                OnboardingCardView(viewModel: viewModel)
                    .frame(width: 400, height: 540)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        headerRow
                        if let e = viewModel.lastError     { ErrorBanner(title: "刷新失败", message: e) }
                        if let e = viewModel.settingsError { ErrorBanner(title: "设置提示", message: e) }
                        quotaCard
                        if let hourly = viewModel.snapshot?.hourlyTokens, hourly.contains(where: { $0 > 0 }) {
                            sparklineCard(hourly: hourly)
                        }
                        statsCard
                        controlsCard
                    }
                    .padding(14)
                }
                .frame(width: 400, height: 660)
            }
            if copyToast {
                Text("已复制到剪贴板")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        Capsule()
                            .fill(Color.black.opacity(0.72))
                    )
                    .foregroundStyle(.white)
                    .padding(.top, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .background(WindowChromeConfigurator(kind: .panel))
        .background(
            Button("") { handleCopySnapshot() }
                .keyboardShortcut("c", modifiers: [.command])
                .opacity(0)
                .frame(width: 0, height: 0)
        )
    }

    private func handleCopySnapshot() {
        guard viewModel.copySnapshotToClipboard() else { return }
        withAnimation(.easeOut(duration: 0.2)) { copyToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            withAnimation(.easeIn(duration: 0.25)) { copyToast = false }
        }
    }

    private func sparklineCard(hourly: [Int]) -> some View {
        PremiumSurface(padding: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("sparkline.header")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let badge = vsYesterdayBadge() {
                        badge
                    }
                }
                SparklineView(values: hourly, accent: GLMChrome.blue, height: 30)
            }
        }
    }

    private func vsYesterdayBadge() -> VsYesterdayBadge? {
        guard let snap = viewModel.snapshot else { return nil }
        let today = snap.totalTokens24h
        guard let yesterday = snap.previousDayTokens else { return nil }

        if yesterday == 0 {
            if today == 0 { return nil }
            return VsYesterdayBadge(kind: .new)
        }

        let delta = Double(today - yesterday) / Double(yesterday) * 100
        let absPct = Int(abs(delta).rounded())
        if absPct < 1 {
            return VsYesterdayBadge(kind: .flat)
        }
        return VsYesterdayBadge(kind: delta >= 0 ? .up(absPct) : .down(absPct))
    }

    // Header: logo · title · plan badge · refresh
    private var headerRow: some View {
        HStack(spacing: 10) {
            BrandMarkView(size: 32)
            Text("GLM 用量监控")
                .font(.system(size: 15, weight: .bold, design: .rounded))
            if let plan = viewModel.snapshot?.planLevel?.uppercased() {
                PlanBadge(text: plan)
                    .help(String(localized: "plan.tooltip"))
            }
            Spacer()
            Button { viewModel.refreshNow() } label: {
                HStack(spacing: 5) {
                    if viewModel.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
                            .frame(width: 13, height: 13)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    Text("刷新")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                }
            }
            .buttonStyle(ChromeButtonStyle())
            .disabled(viewModel.isRefreshing)
        }
        .padding(.horizontal, 2)
    }

    // Both quotas in one card
    private var quotaCard: some View {
        PremiumSurface(padding: 14) {
            VStack(spacing: 10) {
                if let snap = viewModel.snapshot {
                    QuotaRow(metric: snap.fiveHour)
                    Divider().opacity(0.22)
                    QuotaRow(metric: snap.weekly)
                } else {
                    QuotaRowPlaceholder(title: "5h 配额")
                    Divider().opacity(0.22)
                    QuotaRowPlaceholder(title: "周配额")
                }
            }
        }
    }

    // Flat stat rows + model distribution
    private var statsCard: some View {
        PremiumSurface(padding: 14) {
            if let snap = viewModel.snapshot {
                let topModels = Array(snap.modelSummaries.prefix(3))
                let topMax = max(1.0, Double(topModels.map(\.totalTokens).max() ?? 1))
                VStack(spacing: 0) {
                    StatRow(label: "24h Tokens", value: MonitorViewModel.formatTokenCount(snap.totalTokens24h), accent: GLMChrome.blue)
                    Divider().opacity(0.18)
                    StatRow(label: "调用次数",    value: "\(snap.totalCalls24h)",         accent: GLMChrome.teal)
                    Divider().opacity(0.18)
                    StatRow(label: "工具调用",    value: "\(snap.toolTotals.totalCount)", accent: GLMChrome.gold)
                    if !topModels.isEmpty {
                        Divider().opacity(0.22).padding(.vertical, 6)
                        ForEach(topModels) { m in
                            ModelUsageRow(summary: m, topTotal: topMax)
                        }
                    }
                }
            } else {
                Text("暂无数据")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 6)
            }
        }
    }

    // Toggle + interval, connection subtitle, buttons
    private var controlsCard: some View {
        PremiumSurface(padding: 14) {
            VStack(spacing: 12) {
                // Layer 1 — primary control
                HStack(spacing: 10) {
                    Toggle("", isOn: $viewModel.autoRefresh).labelsHidden()
                    Text("自动刷新")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    TextField(
                        "60",
                        value: $viewModel.refreshSeconds,
                        format: .number.precision(.fractionLength(0))
                    )
                    .textFieldStyle(.plain)
                    .frame(width: 36)
                    .multilineTextAlignment(.trailing)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    Text("秒")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Stepper("", value: $viewModel.refreshSeconds, in: 10 ... 3600, step: 10)
                        .labelsHidden()
                }

                // Layer 2 — subtle status subtitle
                HStack(spacing: 4) {
                    Text(hostLabel)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(.quaternary)
                    Text(obfuscatedToken)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Text(viewModel.nextRefreshText)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Divider().opacity(0.22)

                // Layer 3 — actions
                HStack(spacing: 8) {
                    Button {
                        dismissMenuBarPanel()
                        openWindow(id: "settings")
                        NSApp.activate(ignoringOtherApps: true)
                    } label: {
                        Label("设置", systemImage: "slider.horizontal.3")
                    }
                    .buttonStyle(ChromeButtonStyle())
                    Button {
                        NSApp.terminate(nil)
                    } label: {
                        Label("退出", systemImage: "power")
                    }
                    .buttonStyle(ChromeButtonStyle())
                    Spacer()
                    Button { viewModel.applySettings(refresh: true) } label: {
                        Label("应用", systemImage: "checkmark.circle.fill")
                    }
                    .buttonStyle(ChromeButtonStyle(prominent: true))
                }
            }
        }
    }

    private var hostLabel: String {
        URL(string: viewModel.baseURL)?.host ?? "api.z.ai"
    }

    private var obfuscatedToken: String {
        let t = viewModel.authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > 6 else {
            return t.isEmpty ? String(localized: "未填写") : String(localized: "已填写")
        }
        return "\(t.prefix(2))••••\(t.suffix(2))"
    }
}

// MARK: - Onboarding

enum OnboardingRegion: String, CaseIterable, Identifiable {
    case china, global
    var id: String { rawValue }
    var titleKey: LocalizedStringKey {
        self == .china ? "onboarding.region.china" : "onboarding.region.global"
    }
    var baseURL: String {
        self == .china
            ? "https://open.bigmodel.cn/api/anthropic"
            : "https://api.z.ai/api/anthropic"
    }
}

struct OnboardingCardView: View {
    @ObservedObject var viewModel: MonitorViewModel
    var onFinish: (() -> Void)? = nil
    @State private var region: OnboardingRegion = .china
    @State private var tokenDraft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                BrandMarkView(size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("onboarding.title")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    Text("onboarding.subtitle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }

            PremiumSurface(padding: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("onboarding.step1")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("onboarding.step2")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("onboarding.step3")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            PremiumSurface(padding: 14) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        ForEach(OnboardingRegion.allCases) { r in
                            Button {
                                region = r
                            } label: {
                                Text(r.titleKey)
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(region == r ? GLMChrome.blue.opacity(0.14) : Color.primary.opacity(0.04))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                    .strokeBorder(
                                                        region == r ? GLMChrome.blue.opacity(0.4) : Color.white.opacity(0.08),
                                                        lineWidth: region == r ? 1.5 : 1
                                                    )
                                            )
                                    )
                                    .foregroundStyle(region == r ? GLMChrome.blue : .primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    FieldShell {
                        SecureField(String(localized: "onboarding.token.placeholder"), text: $tokenDraft)
                            .textFieldStyle(.plain)
                    }
                    Button {
                        startMonitoring()
                    } label: {
                        HStack {
                            Spacer()
                            Label("onboarding.start", systemImage: "sparkles")
                            Spacer()
                        }
                    }
                    .buttonStyle(ChromeButtonStyle(prominent: true))
                    .disabled(tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            PrivacyNotice()
        }
        .padding(18)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func startMonitoring() {
        let trimmed = tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        viewModel.baseURL = region.baseURL
        viewModel.authToken = trimmed
        viewModel.applySettings(refresh: true)
        onFinish?()
    }
}

// MARK: - Settings window

struct SettingsRootView: View {
    @ObservedObject var viewModel: MonitorViewModel
    @State private var savedToast: Bool = false

    var body: some View {
        ZStack {
            PremiumBackdrop()
            VStack(alignment: .leading, spacing: 10) {
                settingsHeader
                if let e = viewModel.lastError     { ErrorBanner(title: "刷新失败", message: e) }
                if let e = viewModel.settingsError { ErrorBanner(title: "设置提示", message: e) }
                SettingsSectionsView(viewModel: viewModel, onSaved: triggerSavedToast)
                privacyFooter
            }
            .padding(16)

            if savedToast {
                VStack {
                    Spacer()
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(GLMChrome.teal)
                        Text("已保存")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.black.opacity(0.78)))
                    .padding(.bottom, 72)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .background(WindowChromeConfigurator(kind: .settings))
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func triggerSavedToast() {
        withAnimation(.easeOut(duration: 0.2)) { savedToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            withAnimation(.easeIn(duration: 0.25)) { savedToast = false }
        }
    }

    private var settingsHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            BrandMarkView(size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text("设置")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                Text("GLM 用量监控")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Text(URL(string: viewModel.baseURL)?.host ?? "api.z.ai")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }

    private var privacyFooter: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Text("所有配置仅保存在本机 UserDefaults，不上传任何服务器。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.top, 2)
    }
}

// MARK: - Settings sections (three-section single column)

struct SettingsSectionsView: View {
    @ObservedObject var viewModel: MonitorViewModel
    var onSaved: () -> Void = {}
    @State private var showToken: Bool = false
    @State private var showAdvanced: Bool = false

    var body: some View {
        VStack(spacing: 10) {
            accountSection
            refreshAndNotifySection
            appearanceAndStartupSection
            actionFooter
        }
    }

    // MARK: Section 1 — 账号

    private var accountSection: some View {
        SettingsSectionCard(title: "账号") {
            LabeledField(label: "服务地区") {
                Picker("", selection: regionBinding) {
                    Text("国内 · bigmodel.cn").tag(RegionChoice.china)
                    Text("海外 · z.ai").tag(RegionChoice.global)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            LabeledField(label: "Token") {
                FieldShell {
                    HStack(spacing: 8) {
                        Group {
                            if showToken {
                                TextField("Authorization token", text: $viewModel.authToken)
                            } else {
                                SecureField("Authorization token", text: $viewModel.authToken)
                            }
                        }
                        .textFieldStyle(.plain)
                        Button {
                            showToken.toggle()
                        } label: {
                            Image(systemName: showToken ? "eye.slash" : "eye")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(showToken ? String(localized: "隐藏 Token") : String(localized: "显示 Token"))
                    }
                }
            }
            // Base URL is rarely edited — fold into a manual disclosure.
            // (We avoid DisclosureGroup because its built-in animation fights
            // with the window's fixedSize / contentSize resize, which causes
            // visible jank.)
            Button {
                showAdvanced.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showAdvanced ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                    Text("高级")
                        .font(.caption.weight(.semibold))
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showAdvanced {
                LabeledField(label: "Base URL") {
                    FieldShell {
                        TextField("https://api.z.ai/api/anthropic", text: $viewModel.baseURL)
                            .textFieldStyle(.plain)
                    }
                }
            }
        }
    }

    private enum RegionChoice { case china, global }

    private var regionBinding: Binding<RegionChoice> {
        Binding {
            viewModel.baseURL.contains("bigmodel.cn") ? .china : .global
        } set: { choice in
            viewModel.baseURL = (choice == .china)
                ? MonitorViewModel.chinaBaseURL
                : MonitorViewModel.globalBaseURL
        }
    }

    // MARK: Section 2 — 刷新与通知

    private var refreshAndNotifySection: some View {
        SettingsSectionCard(title: "刷新与通知") {
            // 自动刷新 + 间隔 合并到同一行
            FieldShell {
                HStack(spacing: 10) {
                    Toggle(isOn: $viewModel.autoRefresh) {
                        Text("自动刷新").font(.subheadline.weight(.semibold))
                    }
                    Spacer()
                    TextField(
                        "60",
                        value: $viewModel.refreshSeconds,
                        format: .number.precision(.fractionLength(0))
                    )
                    .textFieldStyle(.plain)
                    .frame(width: 52)
                    .multilineTextAlignment(.trailing)
                    .disabled(!viewModel.autoRefresh)
                    Text("秒").font(.caption).foregroundStyle(.secondary)
                    Stepper("", value: $viewModel.refreshSeconds, in: 10 ... 3600, step: 10)
                        .labelsHidden()
                        .disabled(!viewModel.autoRefresh)
                }
            }
            // 阈值提醒 + 权限提示
            FieldShell {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: $viewModel.notificationsEnabled) {
                        Text("阈值提醒 · 到达 80%和 95%时通知")
                            .font(.subheadline.weight(.semibold))
                    }
                    if viewModel.notificationsEnabled {
                        Text("若未收到通知，请在系统设置 → 通知 中允许本 app。")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    // MARK: Section 3 — 外观与启动

    private var appearanceAndStartupSection: some View {
        SettingsSectionCard(title: "外观与启动") {
            // 时区 + 外观 一排两列
            HStack(alignment: .top, spacing: 10) {
                LabeledField(label: "时区") {
                    FieldShell {
                        Picker("", selection: $viewModel.windowTimezoneID) {
                            ForEach(MonitorViewModel.supportedTimezones, id: \.self) { id in
                                Text(id).tag(id)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }
                }
                LabeledField(label: "外观") {
                    Picker("", selection: $viewModel.appearanceMode) {
                        ForEach(AppAppearanceMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
            FieldShell {
                HStack {
                    Toggle(isOn: $viewModel.launchAtLogin) {
                        Text("开机启动").font(.subheadline.weight(.semibold))
                    }
                    Spacer()
                    if viewModel.launchAtLogin {
                        Button {
                            revealLaunchPlistInFinder()
                        } label: {
                            Label("在 Finder 中显示", systemImage: "folder")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(GLMChrome.blue)
                    }
                }
            }
        }
    }

    private func revealLaunchPlistInFinder() {
        let path = (NSString(string: "~/Library/LaunchAgents/local.jing.glm-token-monitor.plist")
            .expandingTildeInPath)
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            // Fallback: just open the LaunchAgents folder
            let folder = url.deletingLastPathComponent()
            NSWorkspace.shared.open(folder)
        }
    }

    // MARK: Footer

    private var actionFooter: some View {
        HStack(spacing: 8) {
            Button { viewModel.resetRecommended() } label: {
                Label("恢复默认", systemImage: "arrow.uturn.backward.circle")
            }
            .buttonStyle(ChromeButtonStyle())
            Spacer()
            Button { save(refresh: true) } label: {
                Label("应用并刷新", systemImage: "checkmark.circle.fill")
            }
            .buttonStyle(ChromeButtonStyle(prominent: true))
            .keyboardShortcut(.return, modifiers: [.command])
        }
        .padding(.top, 4)
        // Hidden ⌘S save shortcut (saves without refresh).
        .background(
            Button("") { save(refresh: false) }
                .keyboardShortcut("s", modifiers: [.command])
                .opacity(0)
                .frame(width: 0, height: 0)
        )
    }

    private func save(refresh: Bool) {
        viewModel.applySettings(refresh: refresh)
        // Only celebrate when nothing blew up during save.
        if viewModel.settingsError == nil {
            onSaved()
        }
    }
}

// MARK: - SettingsSectionCard

struct SettingsSectionCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        PremiumSurface(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    content
                }
            }
        }
    }
}

// MARK: - LabeledField

struct LabeledField<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
    }
}

// MARK: - BrandMarkView

struct BrandMarkView: View {
    let size: CGFloat

    init(size: CGFloat = 44) { self.size = size }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(LinearGradient(
                    colors: [GLMChrome.blue, GLMChrome.teal],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .strokeBorder(.white.opacity(0.20), lineWidth: 1)
            Circle()
                .fill(.white.opacity(0.16))
                .blur(radius: size * 0.10)
                .frame(width: size * 0.38, height: size * 0.38)
                .offset(x: -size * 0.14, y: -size * 0.16)
            Text("G")
                .font(.system(size: size * 0.46, weight: .black, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .shadow(color: GLMChrome.blue.opacity(0.22), radius: 10, x: 0, y: 5)
    }
}

// MARK: - QuotaRow

struct QuotaRow: View {
    let metric: QuotaMetric

    private var color: Color { GLMChrome.quotaColor(metric.percentage) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(metric.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(metric.percentage.rounded()))%")
                    .font(.system(size: 22, weight: .black, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(color)
            }
            ProgressStrip(value: metric.percentage / 100, accent: color)
            if let resetAt = metric.resetAt {
                Text(FriendlyReset.describe(resetAt))
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
            }
        }
    }
}

// MARK: - FriendlyReset

enum FriendlyReset {
    private static let hhmmFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    /// "即将重置" / "50 分钟后重置" / "今天 04:59 重置" /
    /// "明天 11:00 重置" / "5 天后重置 · 11:00"
    static func describe(_ resetAt: Date, now: Date = Date()) -> String {
        let interval = resetAt.timeIntervalSince(now)

        if interval <= 60 {
            return NSLocalizedString("reset.soon", comment: "")
        }

        let minutes = Int(interval / 60)
        if minutes < 60 {
            return String(format: NSLocalizedString("reset.minutes", comment: ""), minutes)
        }

        let cal = Calendar.current
        let startToday = cal.startOfDay(for: now)
        let startReset = cal.startOfDay(for: resetAt)
        let daysDiff = cal.dateComponents([.day], from: startToday, to: startReset).day ?? 0
        let timeStr = hhmmFmt.string(from: resetAt)

        switch daysDiff {
        case ..<1:
            return String(format: NSLocalizedString("reset.today", comment: ""), timeStr)
        case 1:
            return String(format: NSLocalizedString("reset.tomorrow", comment: ""), timeStr)
        default:
            return String(format: NSLocalizedString("reset.days", comment: ""), daysDiff, timeStr)
        }
    }
}

struct QuotaRowPlaceholder: View {
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("--")
                    .font(.system(size: 22, weight: .black, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
            ProgressStrip(value: 0, accent: Color.primary.opacity(0.12))
        }
    }
}

// MARK: - StatRow

struct StatRow: View {
    let label: String
    let value: String
    let accent: Color

    var body: some View {
        HStack {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(accent)
                    .frame(width: 3, height: 13)
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .monospacedDigit()
        }
        .padding(.vertical, 5)
    }
}

// MARK: - PlanBadge

struct PlanBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(GLMChrome.blue)
            .background(
                Capsule()
                    .fill(GLMChrome.blue.opacity(0.12))
                    .overlay(Capsule().strokeBorder(GLMChrome.blue.opacity(0.26), lineWidth: 1))
            )
    }
}

// MARK: - MiniMetricTile (settings window)

struct MiniMetricTile: View {
    let title: String
    let value: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 22, weight: .black, design: .rounded))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(accent.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(accent.opacity(0.18), lineWidth: 1)
                )
        )
    }
}

// MARK: - ModelUsageRow

struct ModelUsageRow: View {
    let summary: ModelSummary
    let topTotal: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(summary.modelName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text(MonitorViewModel.formatTokenCount(summary.totalTokens))
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            ProgressStrip(
                value: Double(summary.totalTokens) / max(1, topTotal),
                accent: GLMChrome.blue.opacity(0.7)
            )
        }
        .padding(.vertical, 3)
    }
}

// MARK: - ProgressStrip

struct ProgressStrip: View {
    let value: Double
    let accent: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.07))
                Capsule()
                    .fill(LinearGradient(
                        colors: [accent, accent.opacity(0.5)],
                        startPoint: .leading, endPoint: .trailing
                    ))
                    .frame(width: max(6, proxy.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: 5)
    }
}

// MARK: - Sparkline

struct SparklineView: View {
    let values: [Int]
    let accent: Color
    var height: CGFloat = 28
    /// Fraction of each cell used by the bar itself (rest is air).
    var barFill: CGFloat = 0.55

    var body: some View {
        let maxV = max(1, values.max() ?? 1)
        GeometryReader { proxy in
            let cellW = values.isEmpty ? 0 : proxy.size.width / CGFloat(values.count)
            let barW = max(2, cellW * barFill)
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, v in
                    let ratio = CGFloat(Double(v) / Double(maxV))
                    ZStack(alignment: .bottom) {
                        Color.clear
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(LinearGradient(
                                colors: [accent.opacity(0.9), accent.opacity(0.35)],
                                startPoint: .top, endPoint: .bottom
                            ))
                            .frame(width: barW, height: max(2, proxy.size.height * ratio))
                    }
                    .frame(width: cellW)
                }
            }
        }
        .frame(height: height)
    }
}

// MARK: - VsYesterdayBadge

struct VsYesterdayBadge: View {
    enum Kind { case up(Int), down(Int), flat, new }
    let kind: Kind

    var body: some View {
        HStack(spacing: 4) {
            if let arrow = arrow {
                Image(systemName: arrow)
                    .font(.system(size: 9, weight: .bold))
            }
            Text(text)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .monospacedDigit()
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .foregroundStyle(.white)
        .background(
            Capsule()
                .fill(accent.opacity(0.85))
                .overlay(Capsule().strokeBorder(accent, lineWidth: 1))
        )
    }

    private var text: String {
        switch kind {
        case .up(let p):
            return String(format: NSLocalizedString("sparkline.vs.up", comment: ""), p)
        case .down(let p):
            return String(format: NSLocalizedString("sparkline.vs.down", comment: ""), p)
        case .flat:
            return NSLocalizedString("sparkline.vs.flat", comment: "")
        case .new:
            return NSLocalizedString("sparkline.vs.new", comment: "")
        }
    }

    private var arrow: String? {
        switch kind {
        case .up:   return "arrow.up.right"
        case .down: return "arrow.down.right"
        case .flat: return "equal"
        case .new:  return nil
        }
    }

    private var accent: Color {
        switch kind {
        case .up:   return GLMChrome.orange
        case .down: return GLMChrome.teal
        case .flat: return Color.gray
        case .new:  return GLMChrome.blue
        }
    }
}

// MARK: - FieldShell

struct FieldShell<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack { content }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(.clear)
                    .background {
                        VisualEffectBlur(material: .menu)
                            .overlay(Color.black.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .strokeBorder(.white.opacity(0.09), lineWidth: 1)
                    )
            )
    }
}

// MARK: - SettingLine

struct SettingLine: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .lineLimit(1)
            Spacer()
        }
    }
}

// MARK: - ErrorBanner

struct ErrorBanner: View {
    let title: String
    let message: String

    var body: some View {
        PremiumSurface(padding: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(GLMChrome.red)
                    .font(.system(size: 13))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }
}

// MARK: - RegionPresetButton

struct RegionPresetButton: View {
    let label: String
    let host: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(isActive ? GLMChrome.blue : .primary)
                Text(host)
                    .font(.system(size: 10))
                    .foregroundStyle(isActive ? GLMChrome.blue.opacity(0.7) : .secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isActive ? GLMChrome.blue.opacity(0.10) : Color.primary.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(
                                isActive ? GLMChrome.blue.opacity(0.35) : Color.white.opacity(0.08),
                                lineWidth: isActive ? 1.5 : 1
                            )
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - PrivacyNotice

struct PrivacyNotice: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(GLMChrome.teal)
                .font(.system(size: 14))
            VStack(alignment: .leading, spacing: 2) {
                Text("数据安全说明")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("所有配置（Token、Base URL 等）均仅保存在本机 UserDefaults 中，不会上传至任何服务器。本 app 不收集、不存储、不传输任何用户数据。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(GLMChrome.teal.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(GLMChrome.teal.opacity(0.18), lineWidth: 1)
                )
        )
    }
}

// MARK: - HeroPill

struct HeroPill: View {
    enum Tone { case accent, neutral }
    let text: String
    let tone: Tone

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .foregroundStyle(tone == .accent ? GLMChrome.blue : Color.primary.opacity(0.7))
            .background(
                Capsule()
                    .fill(fillColor)
                    .overlay(Capsule().strokeBorder(strokeColor, lineWidth: 1))
            )
    }

    private var fillColor: Color {
        tone == .accent ? GLMChrome.blue.opacity(0.12) : Color.primary.opacity(0.05)
    }

    private var strokeColor: Color {
        tone == .accent ? GLMChrome.blue.opacity(0.22) : Color.white.opacity(0.07)
    }
}

// MARK: - ChromeButtonStyle

struct ChromeButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(bg(isPressed: configuration.isPressed))
            .foregroundStyle(prominent ? .white : .primary)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private func bg(isPressed: Bool) -> some View {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(.clear)
            .background {
                Group {
                    if prominent {
                        LinearGradient(
                            colors: [
                                GLMChrome.blue.opacity(isPressed ? 0.84 : 1),
                                GLMChrome.teal.opacity(isPressed ? 0.74 : 0.9),
                            ],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    } else {
                        VisualEffectBlur(material: .popover)
                            .overlay(Color.white.opacity(isPressed ? 0.02 : 0.04))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(
                        prominent ? GLMChrome.blue.opacity(0.22) : Color.white.opacity(0.08),
                        lineWidth: 1
                    )
            )
    }
}

// MARK: - PremiumBackdrop

struct PremiumBackdrop: View {
    var body: some View {
        ZStack {
            VisualEffectBlur(material: .underWindowBackground, blendingMode: .behindWindow)
            Circle().fill(GLMChrome.blue.opacity(0.18)).blur(radius: 100).frame(width: 280, height: 280).offset(x: -180, y: -150)
            Circle().fill(GLMChrome.teal.opacity(0.12)).blur(radius: 100).frame(width: 260, height: 260).offset(x: 200, y: 100)
            Circle().fill(GLMChrome.gold.opacity(0.07)).blur(radius: 120).frame(width: 200, height: 200).offset(x: 60, y: -170)
            LinearGradient(
                colors: [Color.black.opacity(0.18), Color.black.opacity(0.03), Color.black.opacity(0.18)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }
}

// MARK: - PremiumSurface

struct PremiumSurface<Content: View>: View {
    let padding: CGFloat
    @ViewBuilder let content: Content

    init(padding: CGFloat = 18, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(surfaceBg)
    }

    private var surfaceBg: some View {
        RoundedRectangle(cornerRadius: GLMChrome.cardCorner, style: .continuous)
            .fill(.clear)
            .background {
                VisualEffectBlur(material: .hudWindow)
                    .overlay(LinearGradient(
                        colors: [GLMChrome.mutedFill, GLMChrome.deepTint],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    .clipShape(RoundedRectangle(cornerRadius: GLMChrome.cardCorner, style: .continuous))
            }
            .overlay(
                RoundedRectangle(cornerRadius: GLMChrome.cardCorner, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [GLMChrome.glassStroke, Color.white.opacity(0.03)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: GLMChrome.cardCorner, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [GLMChrome.glassHighlight, .clear],
                                       startPoint: .top, endPoint: .center),
                        lineWidth: 1
                    )
                    .blur(radius: 0.4)
            }
            .shadow(color: .black.opacity(0.16), radius: 20, x: 0, y: 12)
    }
}

// MARK: - VisualEffectBlur

struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode = .withinWindow
    var state: NSVisualEffectView.State = .active

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = state
        v.isEmphasized = false
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
        nsView.isEmphasized = false
    }
}

// MARK: - WindowChromeConfigurator

struct WindowChromeConfigurator: NSViewRepresentable {
    enum Kind { case panel, settings }
    let kind: Kind

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { configure(window: v.window) }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(window: nsView.window) }
    }

    private func configure(window: NSWindow?) {
        guard let w = window else { return }
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        switch kind {
        case .panel:
            w.isMovableByWindowBackground = true
        case .settings:
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.isMovableByWindowBackground = true
            w.toolbarStyle = .unifiedCompact
            w.styleMask.insert(.fullSizeContentView)
        }
    }
}
