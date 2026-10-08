import Foundation

enum PrivilegedCommand {
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Only callers build commands. Never pass credentials in this channel.
    static func run(_ command: String) throws -> String {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let result = try SystemProcessRunner().run(
            executable: "/usr/bin/osascript",
            arguments: ["-e", "do shell script \"\(escaped)\" with administrator privileges"],
            timeoutSeconds: nil)
        guard result.succeeded else {
            if result.stderr.contains("(-128)") { throw DependencyInstallError.userCancelled }
            // AppleScript errors may echo the full command. Keep them out of logs/UI.
            throw DependencyInstallError.unsupported(reason: "The authorized operation failed. Check the bundled runtime or contact your administrator.")
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
