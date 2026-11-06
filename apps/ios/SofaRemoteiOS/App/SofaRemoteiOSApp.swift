import AppleCore
import Foundation
import SwiftUI
#if DEBUG && targetEnvironment(simulator)
    import UIKit
#endif

@main
struct SofaRemoteiOSApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = RemoteModel()

    var body: some Scene {
        WindowGroup {
            RemoteView(model: model)
                #if DEBUG
                    .overlay(alignment: .topLeading) {
                        if model.isLiveMediaTesting {
                            Text("\(model.liveSuccessfulResults):\(model.liveFailedResults)")
                            .frame(width: 1, height: 1).opacity(0.01)
                            .accessibilityIdentifier("live.results")
                            .allowsHitTesting(false)
                        }
                    }
                #endif
                #if DEBUG && targetEnvironment(simulator)
                    .transaction { transaction in
                        if model.isUITesting { transaction.disablesAnimations = true }
                    }
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
            // Functional UI tests must not depend on Simulator animation completion.
            if isActive { UIView.setAnimationsEnabled(false) }
        }

        var commandLogJSON: String {
            guard let data = try? JSONEncoder().encode(commandLog) else { return "[]" }
            return String(bytes: data, encoding: .utf8) ?? "[]"
        }

        var initialState: RemoteState? {
            guard isActive, scenario != .disconnected else { return nil }
            let controls = scenario?.supportsSessionControls == true
            let known = scenario != .sessionControlsUnknown
            let locked: Bool? =
                controls
                ? (known
                    ? scenario == .sessionControlsLocked || scenario == .sessionControlsOff : nil)
                : (scenario == .unlockReady || scenario == .unlockDenied ? true : nil)
            return RemoteState(
                accessibilityGranted: scenario != .permissionDenied
                    && scenario != .sessionControlsNoAccessibility,
                systemVolume: scenario == .unsupportedVolume ? nil : 0,
                systemVolumeReason: scenario == .unsupportedVolume
                    ? "System volume control is unavailable on this Mac." : nil,
                deviceName: scenario == .longName
                    ? "Living Room MacBook Pro with an external display" : "UI Test Mac",
                supportsGestures: scenario == .legacyCompanion ? nil : true,
                capabilities: controls
                    ? [
                        WireCapabilities.remoteUnlock, WireCapabilities.remoteLock,
                        WireCapabilities.displayPower
                    ]
                    : (scenario == .unlockReady || scenario == .unlockDenied
                        ? [WireCapabilities.remoteUnlock] : nil),
                sessionLocked: locked,
                unlockAvailable: controls
                    ? scenario != .sessionControlsNoAccessibility
                    : (scenario == .unlockReady ? true : nil),
                displayAsleep: controls && known ? scenario == .sessionControlsOff : nil)
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
            switch command.name {
            case .sessionUnlock: state.sessionLocked = false
            case .sessionLock: state.sessionLocked = true
            case .displayOff: state.displayAsleep = true
            case .displayWake: state.displayAsleep = false
            case .sessionLockAndDisplayOff:
                state.sessionLocked = true
                state.displayAsleep = true
            default: break
            }
            remoteState = state
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
            if command.name == .sessionUnlock || SessionControlPolicy.isControl(command.name) {
                return SessionControlPolicy.allows(command.name, state: state)
            }
            return state.accessibilityGranted
        }

        private static func scenario(in arguments: [String]) -> UITestScenario? {
            guard
                let argument = arguments.first(where: {
                    $0.hasPrefix("--ui-testing-scenario=")
                })
            else { return nil }
            return UITestScenario(
                rawValue: String(argument.dropFirst("--ui-testing-scenario=".count)))
        }
    }

    private enum UITestScenario: String, Equatable {
        case disconnected
        case longName = "long-name"
        case unsupportedVolume = "unsupported-volume"
        case permissionDenied = "permission-denied"
        case legacyCompanion = "legacy-companion"
        case unlockReady = "unlock-ready"
        case unlockDenied = "unlock-denied"
        case sessionControls = "session-controls"
        case sessionControlsLocked = "session-controls-locked"
        case sessionControlsOff = "session-controls-off"
        case sessionControlsUnknown = "session-controls-unknown"
        case sessionControlsNoAccessibility = "session-controls-no-accessibility"

        var supportsSessionControls: Bool {
            switch self {
            case .sessionControls, .sessionControlsLocked, .sessionControlsOff,
                .sessionControlsUnknown, .sessionControlsNoAccessibility:
                true
            default: false
            }
        }
    }
#endif
