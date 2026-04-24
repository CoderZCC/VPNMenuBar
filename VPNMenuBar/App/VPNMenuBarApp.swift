import SwiftUI
import AppKit
import UserNotifications
import Combine
import Sparkle

@main
struct VPNMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var coordinator = AppCoordinator()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(
                controller: coordinator.controller,
                onOpenSettings: coordinator.openSettings,
                onCheckDependencies: coordinator.openDependencyAlert,
                onAbout: coordinator.openAbout,
                updaterController: coordinator.updaterController
            )
        } label: {
            Image(nsImage: StatusBarIconFactory.image(for: coordinator.controller.state))
        }
        .menuBarExtraStyle(.menu)
    }
}

/// App delegate that intercepts termination to ensure the VPN is disconnected first.
/// Fires on every quit path: menu Quit, Cmd-Q, Dock force-quit, system logout, etc.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // If the coordinator hasn't been created yet, or the VPN isn't connected,
        // nothing to do — let the app exit immediately.
        guard let coordinator = AppCoordinator.shared,
              coordinator.controller.state.isConnected else {
            return .terminateNow
        }
        // VPN is up — disconnect asynchronously, then approve termination.
        Task { @MainActor in
            await coordinator.controller.disconnect()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// Owns the singleton controller and manages auxiliary windows (Onboarding, DependencyAlert).
@MainActor
final class AppCoordinator: ObservableObject {
    /// Weak shared reference so the AppDelegate can reach the coordinator during
    /// `applicationShouldTerminate` without going through SwiftUI state.
    static weak var shared: AppCoordinator?

    let configStore: ConfigStore
    let dependencyChecker: DependencyChecker
    let controller: VPNController
    let updaterController: SPUStandardUpdaterController

    private var onboardingWindow: NSWindow?
    private var dependencyAlertWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var aboutWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    init() {
        let store = ConfigStore()
        let checker = DependencyChecker()
        self.configStore = store
        self.dependencyChecker = checker
        self.controller = VPNController(
            configStore: store,
            dependencyChecker: checker,
            openConnectProcess: OpenConnectProcess()
        )
        self.updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        Self.shared = self

        AppCoordinator.logStartupBanner()

        // Republish controller's state changes so SwiftUI re-renders the MenuBarExtra label
        // (which reads coordinator.controller.state but is only observing coordinator).
        controller.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Skip UI/notification side effects when launched as the xctest host —
        // the test runner injects the test bundle into this app binary and
        // opening NSWindows during SwiftUI's @StateObject init triggers
        // "setting value during update" precondition aborts.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }

        // Defer side effects out of init so SwiftUI construction completes first.
        Task { @MainActor [weak self] in
            self?.requestNotificationPermission()
            LoginItemManager.applyPreference()
            self?.controller.startNetworkMonitoring()
            self?.showOnboardingIfNeeded()
            self?.scheduleAutoConnectIfNeeded()
        }
    }

    /// Kicks off a delayed `controller.connect()` when the user has opted into
    /// auto-connect-on-launch AND setup is already complete. Success flips
    /// `shouldAutoReconnect` inside the controller, so later network drops
    /// auto-recover through the existing reachability path.
    private func scheduleAutoConnectIfNeeded() {
        guard AutoConnectPreference.isEnabled, configStore.isConfigured else { return }
        AppLogger.shared.info("auto-connect on launch scheduled (5s delay)")
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
            guard let self else { return }
            guard case .disconnected = self.controller.state else {
                AppLogger.shared.info("auto-connect skipped — state=\(self.controller.state)")
                return
            }
            AppLogger.shared.info("auto-connect firing")
            await self.controller.connect()
        }
    }

    private static func logStartupBanner() {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let arch = ArchDetector.current == .appleSilicon ? "arm64" : "x86_64"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        AppLogger.shared.info("===== VPNMenuBar launch v\(version) (\(build)) arch=\(arch) os=\(os) bundle=\(bundle.bundlePath) =====")
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func showOnboardingIfNeeded() {
        if !configStore.isConfigured {
            openOnboarding()
        }
    }

    func openSettings() {
        if let win = settingsWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = SettingsView(
            controller: controller,
            configStore: configStore
        )
        let hosting = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: hosting)
        win.title = "Settings"
        win.styleMask = [.titled, .closable]
        win.center()
        win.isReleasedWhenClosed = false
        settingsWindow = win

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: win,
            queue: .main
        ) { [weak self] _ in
            self?.settingsWindow = nil
        }

        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func openOnboarding() {
        if let win = onboardingWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = OnboardingView(
            controller: controller,
            configStore: configStore,
            onFinished: { [weak self] in
                self?.onboardingWindow?.close()
                self?.onboardingWindow = nil
            }
        )
        let hosting = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: hosting)
        win.title = "Setup"
        win.styleMask = [.titled, .closable]
        win.center()
        win.isReleasedWhenClosed = false
        onboardingWindow = win

        // Observe user-initiated close (traffic-light) so we can transition to
        // "Setup incomplete" if config still isn't complete.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: win,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.onboardingWindow = nil
            if !self.configStore.isConfigured {
                self.controller.markSetupIncomplete()
            }
        }

        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func openAbout() {
        if let win = aboutWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: AboutView())
        let win = NSWindow(contentViewController: hosting)
        win.title = "About VPN MenuBar"
        win.styleMask = [.titled, .closable]
        win.center()
        win.isReleasedWhenClosed = false
        aboutWindow = win

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: win,
            queue: .main
        ) { [weak self] _ in
            self?.aboutWindow = nil
        }

        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func openDependencyAlert() {
        if let win = dependencyAlertWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = DependencyAlertView(
            controller: controller,
            configStore: configStore,
            onClose: { [weak self] in
                self?.dependencyAlertWindow?.close()
                self?.dependencyAlertWindow = nil
            }
        )
        let hosting = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: hosting)
        win.title = "Dependencies"
        win.styleMask = [.titled, .closable]
        win.center()
        win.isReleasedWhenClosed = false
        dependencyAlertWindow = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
