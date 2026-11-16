import Foundation
import MacSupport

#if os(macOS)
    import Darwin

    let usage = """
        Usage: SofaRemoteControl [--socket PATH] status|list
               SofaRemoteControl [--socket PATH] get CONTROL [--device ID]
               SofaRemoteControl [--socket PATH] invoke CONTROL [--value true|false] [--device ID] [--path PATH]

        Uses the current user's local Unix socket. JSON output; no automatic retries.
        An accepted action may still be busy or waiting for a system dialog. Read status afterward.
        """

    func parse(_ arguments: [String]) throws -> (URL, LocalAutomationRequest) {
        var arguments = arguments
        var endpoint = LocalAutomationClient.socketURL
        if arguments.first == "--socket" {
            guard arguments.count >= 3, arguments[1].hasPrefix("/") else {
                throw LocalAutomationFailure.invalidFrame
            }
            endpoint = URL(fileURLWithPath: arguments[1])
            arguments.removeFirst(2)
        }
        guard let name = arguments.first,
            let operation = LocalAutomationRequest.Operation(rawValue: name)
        else { throw LocalAutomationFailure.invalidFrame }
        arguments.removeFirst()
        var control: CompanionControl?
        if operation == .get || operation == .invoke {
            guard let name = arguments.first, let selected = CompanionControl(rawValue: name) else {
                throw LocalAutomationFailure.invalidFrame
            }
            control = selected
            arguments.removeFirst()
        }
        var options: [String: String] = [:]
        while !arguments.isEmpty {
            guard arguments.count >= 2, ["--value", "--device", "--path"].contains(arguments[0]),
                options[arguments[0]] == nil
            else { throw LocalAutomationFailure.invalidFrame }
            options[arguments[0]] = arguments[1]
            arguments.removeFirst(2)
        }
        let request = LocalAutomationRequest(
            operation, control: control, value: options["--value"],
            deviceID: options["--device"], path: options["--path"])
        guard request.isValid else { throw LocalAutomationFailure.invalidFrame }
        return (endpoint, request)
    }

    if CommandLine.arguments.dropFirst().contains("--help") {
        print(usage)
        exit(0)
    }
    do {
        let (endpoint, request) = try parse(Array(CommandLine.arguments.dropFirst()))
        let response = try LocalAutomationClient.send(request, to: endpoint)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(response) + Data([10]))
        exit(response.outcome == .success || response.outcome == .accepted ? 0 : 1)
    } catch {
        FileHandle.standardError.write(
            Data((error.localizedDescription + "\n" + usage + "\n").utf8))
        exit(2)
    }
#else
    fatalError("Local automation requires macOS.")
#endif
