import SwiftUI

@main
struct SofaRemoteiOSApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = RemoteModel()

    var body: some Scene {
        WindowGroup {
            RemoteView(model: model)
                .task {
                    model.startDiscovery()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        model.startDiscovery()
                    } else {
                        model.suspend()
                    }
                }
        }
    }
}
