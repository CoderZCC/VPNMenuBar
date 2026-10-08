import Foundation

// Keep isolated tests out of the user's real diagnostic logs.
final class AppLogger {
    static let shared = AppLogger()
    func info(_ message: String) { }
    func warn(_ message: String) { }
    func error(_ message: String) { }
}
