import SwiftUI

@main
struct MotionBrushApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .statusBarHidden()
                .persistentSystemOverlays(.hidden)
        }
    }
}
