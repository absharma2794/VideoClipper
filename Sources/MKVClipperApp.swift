import SwiftUI

@main
struct MKVClipperApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 520, minHeight: 380)
        }
        .windowResizability(.contentSize)
    }
}
