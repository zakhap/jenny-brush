import SwiftUI

@main
struct MotionBrushApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .statusBarHidden()
                .persistentSystemOverlays(.hidden)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background || phase == .inactive {
                model.persistCanvas()   // FR-26: canvas survives termination
            }
        }
    }
}
