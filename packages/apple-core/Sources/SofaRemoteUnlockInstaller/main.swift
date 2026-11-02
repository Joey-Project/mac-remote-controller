import Foundation
import MacSupport

do {
    try UnlockDeployment.run(arguments: Array(CommandLine.arguments.dropFirst()))
    print("{\"status\":\"passed\"}")
} catch {
    let category = (error as? UnlockFailure)?.rawValue ?? "setup-failed"
    print("{\"status\":\"failed\",\"category\":\"\(category)\"}")
    exit(1)
}
