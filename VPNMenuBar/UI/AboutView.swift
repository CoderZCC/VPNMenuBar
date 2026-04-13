import SwiftUI

struct AboutView: View {
    private let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "VPN MenuBar"
    private let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
    private let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "–"
    private let copyright = Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String ?? ""

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)

            Text(appName)
                .font(.title2).bold()

            Text("Version \(version) (\(build))")
                .font(.callout)
                .foregroundColor(.secondary)

            Text(copyright)
                .font(.caption)
                .foregroundColor(.secondary)

            Divider()

            Link("GitHub Repository",
                 destination: URL(string: "https://github.com/CoderZCC/VPNMenuBar")!)
                .font(.callout)
        }
        .padding(24)
        .frame(width: 280)
    }
}
