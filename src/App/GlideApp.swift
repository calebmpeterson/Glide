import SwiftUI

@main
struct GlideApp: App {
    @StateObject private var controller = GlideController()

    var body: some Scene {
        WindowGroup("Glide") {
            PreferencesView(controller: controller)
                .frame(minWidth: 520, minHeight: 490)
        }
        .windowResizability(.contentSize)
    }
}
