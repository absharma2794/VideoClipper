import AppKit

/// Ensures no ffmpeg export is left running as an orphaned background
/// process after the app quits -- Process objects spawned by this app are
/// independent OS processes and are not killed automatically just because
/// the parent app exits.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        RunningExports.shared.terminateAll()
        return .terminateNow
    }
}
