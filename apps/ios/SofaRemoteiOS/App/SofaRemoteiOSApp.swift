import AppleCore
import SwiftUI

@main
struct SofaRemoteiOSApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

private struct ContentView: View {
    private let status = ConnectionStatus.disconnected

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "macbook")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("Sofa Remote")
                .font(.largeTitle.weight(.semibold))

            Text(status.summary)
                .foregroundStyle(.secondary)

            Text("Remote controls are not available yet.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
