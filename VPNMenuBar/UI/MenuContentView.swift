import SwiftUI
import Sparkle

struct MenuContentView: View {
    @ObservedObject var controller: VPNController
    var onOpenSettings: () -> Void
    var onCheckDependencies: () -> Void
    var onAbout: () -> Void
    let updaterController: SPUStandardUpdaterController

    var body: some View {
        // Status header — disabled item, shows current state + gateway hint.
        Text(headerText)
            .disabled(true)

        Divider()

        // When Onboarding was dismissed without completing setup, lock the menu down
        // to just Check Dependencies + Quit. All other operations are hidden.
        if !controller.state.isSetupIncomplete {
            switch controller.state {
            case .disconnected, .failed:
                Button("Connect") {
                    Task { await controller.connect() }
                }
            case .connecting:
                Button("Connecting…") {}
                    .disabled(true)
            case .connected:
                Button("Disconnect") {
                    Task { await controller.disconnect() }
                }
                Button("Reconnect") {
                    Task { await controller.reconnect() }
                }
            }

            Divider()

            Button("Open Settings…") { onOpenSettings() }
        }

        Button("Check Dependencies…") { onCheckDependencies() }

        Button("Check for Updates…") {
            updaterController.checkForUpdates(nil)
        }

        Button("About VPN MenuBar") { onAbout() }

        Divider()

        Button("Quit") {
            // AppDelegate.applicationShouldTerminate disconnects the VPN if needed.
            NSApplication.shared.terminate(nil)
        }
    }

    private var headerText: String {
        switch controller.state {
        case .disconnected:
            return "VPN: Disconnected"
        case .connecting:
            return "VPN: Connecting…"
        case .connected:
            return "VPN: Connected"
        case .failed(let reason):
            // Clip long reasons for menu width.
            let clipped = reason.count > 60 ? String(reason.prefix(57)) + "…" : reason
            return "VPN: \(clipped)"
        }
    }
}
