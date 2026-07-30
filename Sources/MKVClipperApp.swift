import SwiftUI

@main
struct MKVClipperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 520, minHeight: 380)
        }
        .windowResizability(.contentSize)
    }
}
