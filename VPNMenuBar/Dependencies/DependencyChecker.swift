import Foundation

enum DependencyID: String { case openconnect, legacyPermissions, vpncScript, intranetResolvers }

enum InAppFix: Equatable {
    case removeLegacySudoers(username: String)
    case resetManagedRuntime
    case installResolverFiles(rules: [ResolverRule], gatewayHost: String)
}

struct DependencyStatus: Equatable {
    let id: DependencyID
    let passed: Bool
    let detail: String
    let fixHint: String
    let fixCommand: String?
    let inAppFix: InAppFix?
    let isSkipped: Bool
    let isAdvisory: Bool

    init(id: DependencyID, passed: Bool, detail: String, fixHint: String,
         fixCommand: String?, inAppFix: InAppFix?, isSkipped: Bool = false, isAdvisory: Bool = false) {
        self.id = id
        self.passed = passed
        self.detail = detail
        self.fixHint = fixHint
        self.fixCommand = fixCommand
        self.inAppFix = inAppFix
        self.isSkipped = isSkipped
        self.isAdvisory = isAdvisory
    }
}

class DependencyChecker {
    private let runner: ProcessRunning
    private let username: String
    private let fileManager: FileManager

    init(runner: ProcessRunning = SystemProcessRunner(), username: String = NSUserName(), fileManager: FileManager = .default) {
        self.runner = runner
        self.username = username
        self.fileManager = fileManager
    }

    func check(config: VPNConfig) -> [DependencyStatus] {
        var statuses: [DependencyStatus] = []
        do {
            try ManagedRuntime.validateConfiguration(config)
            let result = try runner.run(executable: "/bin/sh", arguments: ["-c", ManagedRuntime.validationCommand], timeoutSeconds: 10)
            statuses.append(DependencyStatus(id: .openconnect, passed: result.succeeded,
                detail: result.succeeded ? "Bundled VPN runtime verified" : "Bundled VPN runtime is missing or damaged",
                fixHint: "Reinstall the complete VPNMenuBar app. No Homebrew or developer tools are required.",
                fixCommand: nil, inAppFix: nil))
        } catch {
            statuses.append(DependencyStatus(id: .openconnect, passed: false,
                detail: error.localizedDescription,
                fixHint: "Use the bundled runtime and frozen no-DNS script.",
                fixCommand: nil, inAppFix: .resetManagedRuntime))
        }
        let legacy = DependencyInstaller.legacySudoersPaths(username: username).filter { fileManager.fileExists(atPath: $0) }
        statuses.append(DependencyStatus(id: .legacyPermissions, passed: legacy.isEmpty,
            detail: legacy.isEmpty ? "No legacy app-owned sudoers file detected" : "Legacy passwordless sudo permissions must be removed",
            fixHint: "Remove this app's old generated rules through system authorization. Other sudoers policies must be reviewed by IT.",
            fixCommand: nil, inAppFix: legacy.isEmpty ? nil : .removeLegacySudoers(username: username), isAdvisory: true))
        let rules = config.resolverRules ?? []
        let pending = ResolverFileManager.pendingRules(rules)
        let orphans = ResolverFileManager.orphanedDomains(keeping: rules)
        let dangerous = ResolverRule.rulesCapturingGateway(rules, gatewayHost: OpenConnectProcess.extractHost(from: config.gateway))
        let dnsOK = pending.isEmpty && orphans.isEmpty && dangerous.isEmpty
        statuses.append(DependencyStatus(id: .intranetResolvers, passed: dnsOK,
            detail: dnsOK ? "DNS rules match the saved configuration" : "DNS rules require review",
            fixHint: dangerous.isEmpty ? "Install only VPN-administrator-approved domains. Existing unmanaged resolver files will not be overwritten." : "A rule would capture the VPN gateway; correct it in Settings.",
            fixCommand: nil,
            inAppFix: dnsOK || !dangerous.isEmpty ? nil : .installResolverFiles(rules: rules, gatewayHost: OpenConnectProcess.extractHost(from: config.gateway)),
            isAdvisory: true))
        return statuses
    }
}
