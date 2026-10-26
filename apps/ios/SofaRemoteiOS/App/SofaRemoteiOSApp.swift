import AppleCore
import Foundation
import SwiftUI

@main
struct SofaRemoteiOSApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = RemoteModel()

    var body: some Scene {
        WindowGroup {
            RemoteView(model: model)
                #if DEBUG && targetEnvironment(simulator)
                    .overlay(alignment: .topLeading) {
                        if model.isUITesting {
                            Text(model.uiTestCommandLogJSON)
                            .frame(width: 1, height: 1)
                            .opacity(0.01)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(model.uiTestCommandLogJSON)
                            .accessibilityIdentifier("uitest.commands")
                            .allowsHitTesting(false)
                        }
                    }
                #endif
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

#if DEBUG && targetEnvironment(simulator)
    @MainActor
    final class UITestFixture {
        private let scenario: UITestScenario?
        let isActive: Bool
        private(set) var commandLog: [RemoteCommand] = []
        private let commandLimit = 128

        init(arguments: [String] = ProcessInfo.processInfo.arguments) {
            isActive = arguments.contains("--ui-testing")
            scenario = Self.scenario(in: arguments)
        }

        var commandLogJSON: String {
            guard let data = try? JSONEncoder().encode(commandLog) else { return "[]" }
            return String(bytes: data, encoding: .utf8) ?? "[]"
        }

        var initialState: RemoteState? {
            guard isActive else { return nil }
            return RemoteState(
                accessibilityGranted: scenario != .permissionDenied,
                systemVolume: scenario == .unsupportedVolume ? nil : 0,
                systemVolumeReason: scenario == .unsupportedVolume
                    ? "System volume control is unavailable on this Mac." : nil,
                deviceName: "UI Test Mac",
                supportsGestures: scenario == .legacyCompanion ? nil : true)
        }

        func send(
            _ command: RemoteCommand, remoteState: inout RemoteState?, errorMessage: inout String?
        ) -> Bool {
            do { try command.validate() } catch {
                errorMessage = "The control value is invalid."; return false
            }
            guard var state = remoteState, isSupported(command, state: state) else { return false }
            append(command)
            if command.name == .systemVolumeSet, let value = command.value {
                state.systemVolume = value
                remoteState = state
            }
            return true
        }

        private func append(_ command: RemoteCommand) {
            commandLog.append(command)
            if commandLog.count > commandLimit {
                commandLog.removeFirst(commandLog.count - commandLimit)
            }
        }

        private func isSupported(_ command: RemoteCommand, state: RemoteState) -> Bool {
            if command.name == .systemVolumeSet { return state.systemVolume != nil }
            return state.accessibilityGranted
        }

        private static func scenario(in arguments: [String]) -> UITestScenario? {
            guard
                let argument = arguments.first(where: {
                    $0.hasPrefix("--ui-testing-scenario=")
                })
            else { return nil }
            switch argument.dropFirst("--ui-testing-scenario=".count) {
            case "unsupported-volume": return .unsupportedVolume
            case "permission-denied": return .permissionDenied
            case "legacy-companion": return .legacyCompanion
            default: return nil
            }
        }
    }

    private enum UITestScenario: Equatable {
        case unsupportedVolume
        case permissionDenied
        case legacyCompanion
    }
#endif
