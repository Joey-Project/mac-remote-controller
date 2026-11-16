import Foundation

/// Enforces the same visible/enabled controls, with no arbitrary method dispatch.
@MainActor
public struct LocalAutomationRouter {
    public let controls: [LocalControlDescriptor]
    public let values: [String: String]
    public let unlocked: Bool
    private let readValue: (CompanionControl) -> String?
    private let invoke: (LocalAutomationRequest) -> Void

    public init(
        controls: [LocalControlDescriptor], values: [String: String], unlocked: Bool,
        readValue: @escaping (CompanionControl) -> String?,
        invoke: @escaping (LocalAutomationRequest) -> Void
    ) {
        self.controls = controls; self.values = values; self.unlocked = unlocked
        self.readValue = readValue; self.invoke = invoke
    }

    public func handle(
        _ request: LocalAutomationRequest, deadline: ContinuousClock.Instant
    ) -> LocalAutomationResponse {
        guard request.isValid else { return LocalAutomationResponse(.invalidRequest) }
        guard ContinuousClock.now < deadline, !Task.isCancelled else {
            return LocalAutomationResponse(
                .unavailable, message: "Request expired before execution.")
        }
        switch request.operation {
        case .status: return LocalAutomationResponse(.success, values: values)
        case .list: return LocalAutomationResponse(.success, controls: controls)
        case .get, .invoke: break
        }
        guard let control = request.control,
            let descriptor = controls.first(where: {
                $0.id == control && $0.deviceID == request.deviceID
            })
        else {
            return LocalAutomationResponse(.invalidRequest, message: "Unknown control or device.")
        }
        guard descriptor.visible else {
            return LocalAutomationResponse(
                .unavailable, message: "Control is not currently visible.")
        }
        if request.operation == .get {
            return readControl(control, descriptor: descriptor)
        }
        guard unlocked, descriptor.enabled else {
            return LocalAutomationResponse(
                .unavailable, message: "Control is disabled or the Mac is locked.")
        }
        guard Self.validArguments(request, descriptor: descriptor) else {
            return LocalAutomationResponse(.invalidRequest, message: "Invalid control arguments.")
        }
        invoke(request)
        return LocalAutomationResponse(
            .accepted,
            message:
                "Action accepted. Read status for its outcome; system dialogs remain interactive.")
    }

    private func readControl(
        _ control: CompanionControl, descriptor: LocalControlDescriptor
    ) -> LocalAutomationResponse {
        guard descriptor.kind != .value || unlocked else {
            return LocalAutomationResponse(.unavailable, message: "Unlock the Mac first.")
        }
        let value = descriptor.kind == .value ? readValue(control) : descriptor.value
        return LocalAutomationResponse(
            .success, controls: [descriptor], values: value.map { ["value": $0] })
    }

    private static func validArguments(
        _ request: LocalAutomationRequest, descriptor: LocalControlDescriptor
    ) -> Bool {
        switch descriptor.kind {
        case .toggle, .disclosure:
            guard request.value == "true" || request.value == "false" else { return false }
        case .button:
            guard request.value == nil else { return false }
        case .value: return false
        }
        if request.control == .recoveryChooseSetup {
            return request.path == nil || request.path?.hasPrefix("/") == true
        }
        return request.path == nil
    }
}
