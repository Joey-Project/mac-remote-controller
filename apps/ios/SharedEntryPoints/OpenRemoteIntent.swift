import AppIntents
import AppleCore
import Foundation
import Observation

/// Fixed foreground actions avoid resolving a screen enum across app processes.
struct OpenTouchpadIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Sofa Remote Touchpad"
    static var openAppWhenRun: Bool { true }

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .foreground }

    func perform() async throws -> some IntentResult {
        await RemoteEntryRouter.shared.open(.touchpad)
        return .result()
    }
}

struct OpenKeyboardIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Sofa Remote Keyboard"
    static var openAppWhenRun: Bool { true }

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .foreground }

    func perform() async throws -> some IntentResult {
        await RemoteEntryRouter.shared.open(.keyboard)
        return .result()
    }
}

@MainActor
@Observable
final class RemoteEntryRouter {
    static let shared = RemoteEntryRouter()

    struct Request: Equatable {
        let id = UUID()
        let destination: RemoteEntryPoint
    }

    var request: Request?

    func open(_ destination: RemoteEntryPoint) {
        request = Request(destination: destination)
    }

    func open(_ url: URL) {
        guard let destination = RemoteEntryPoint(url: url) else { return }
        open(destination)
    }
}
