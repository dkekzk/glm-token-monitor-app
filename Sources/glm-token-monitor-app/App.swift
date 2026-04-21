import AppKit
import SwiftUI

@main
struct GLMTokenMonitorApp: App {
    @StateObject private var viewModel = MonitorViewModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            StatusPanelView(viewModel: viewModel)
                .preferredColorScheme(viewModel.appearanceMode.colorScheme)
        } label: {
            StatusLabelView(
                snapshot: viewModel.snapshot,
                lastError: viewModel.lastError,
                isRefreshing: viewModel.isRefreshing
            )
        }
        .menuBarExtraStyle(.window)

        Window("GLM 设置", id: "settings") {
            SettingsRootView(viewModel: viewModel)
                .preferredColorScheme(viewModel.appearanceMode.colorScheme)
        }
        .defaultSize(width: 560, height: 640)
        .windowResizability(.contentSize)
    }
}

// MARK: - AppDelegate (first-run onboarding window)

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var onboardingWindow: NSWindow?
    private var rightClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installRightClickMonitor()
        // Give the SwiftUI @StateObject a run-loop tick to materialize.
        DispatchQueue.main.async { [weak self] in
            self?.maybeShowOnboardingWindow()
        }
    }

    // MARK: - Right-click on the menu-bar item

    /// SwiftUI MenuBarExtra(.window) ignores right-click. We intercept it via a
    /// local NSEvent monitor and pop a tiny native NSMenu with the most-wanted
    /// quick actions. Left-click still opens the popover as usual.
    private func installRightClickMonitor() {
        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown]) { [weak self] event in
            guard let self = self else { return event }
            guard let window = event.window else { return event }
            let cls = String(describing: type(of: window))
            // Match the status-bar button's host window across macOS versions.
            guard cls.contains("StatusBar") ||
                  cls.contains("MenuBarExtra") else { return event }
            self.showRightClickMenu(with: event)
            return nil // consume the event so SwiftUI doesn't see it
        }
    }

    private func showRightClickMenu(with event: NSEvent) {
        // Close the popover if it's open — feels weird to show a context menu
        // over the popover.
        dismissMenuBarPanel()

        let menu = NSMenu()

        let refresh = NSMenuItem(
            title: NSLocalizedString("立即刷新", comment: ""),
            action: #selector(rcRefresh),
            keyEquivalent: "r"
        )
        refresh.target = self
        menu.addItem(refresh)

        let settings = NSMenuItem(
            title: NSLocalizedString("设置", comment: "") + "…",
            action: #selector(rcSettings),
            keyEquivalent: ","
        )
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: NSLocalizedString("退出", comment: ""),
            action: #selector(rcQuit),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)

        if let view = event.window?.contentView {
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        }
    }

    @objc private func rcRefresh() {
        MonitorViewModel.shared?.refreshNow()
    }

    @objc private func rcSettings() {
        NotificationCenter.default.post(name: .openSettingsRequested, object: nil)
    }

    @objc private func rcQuit() {
        NSApp.terminate(nil)
    }

    private func maybeShowOnboardingWindow() {
        guard let vm = MonitorViewModel.shared else { return }
        guard !vm.hasToken else { return }

        let root = OnboardingCardView(viewModel: vm) { [weak self] in
            self?.closeOnboardingWindow()
        }
        .preferredColorScheme(vm.appearanceMode.colorScheme)

        let hosting = NSHostingController(rootView: root)
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.title = NSLocalizedString("GLM 用量监控", comment: "")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.isReleasedWhenClosed = false
        window.center()
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        onboardingWindow = window
    }

    private func closeOnboardingWindow() {
        onboardingWindow?.close()
        onboardingWindow = nil
    }
}
