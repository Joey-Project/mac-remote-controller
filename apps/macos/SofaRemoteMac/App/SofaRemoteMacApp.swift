import AppleCore
import SwiftUI

@main
struct SofaRemoteMacApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

private struct ContentView: View {
    private let status = ConnectionStatus.disconnected

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "macbook")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)

            Text("Sofa Remote")
                .font(.title2.weight(.semibold))

            Text(status.summary)
                .foregroundStyle(.secondary)

            Text("Remote controls are not available yet.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .frame(minWidth: 320, minHeight: 220)
        .padding()
    }
}
