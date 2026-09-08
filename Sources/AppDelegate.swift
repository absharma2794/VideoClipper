import AppKit

/// Ensures no ffmpeg export is left running as an orphaned background
/// process after the app quits -- Process objects spawned by this app are
/// independent OS processes and are not killed automatically just because
/// the parent app exits.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Stops the queue's run loop from starting another job in the sliver
        // of time before the app actually exits -- the hard kill of whatever
        // is still running is RunningExports.terminateAll() below, unchanged.
        ExportQueue.shared.cancelAll()
        RunningExports.shared.terminateAll()
        return .terminateNow
    }
}
