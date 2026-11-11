import AppIntents
import AppleCore
import Foundation
import Observation

enum RemoteEntryMode: String, AppEnum {
    case touchpad
    case keyboard

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Remote mode")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .touchpad: "Touchpad", .keyboard: "Keyboard"
    ]

    var entryPoint: RemoteEntryPoint {
        switch self {
        case .touchpad: .touchpad
        case .keyboard: .keyboard
        }
    }
}

/// Shared target membership lets the system run this opening intent in the app.
struct OpenRemoteIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Sofa Remote"
    static let description = IntentDescription("Open the touchpad or keyboard on this device.")

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .foreground }

    @Parameter(title: "Mode") var target: RemoteEntryMode

    init() {}

    init(target: RemoteEntryMode) {
        self.target = target
    }

    func perform() async throws -> some IntentResult {
        await RemoteEntryRouter.shared.open(target.entryPoint)
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
