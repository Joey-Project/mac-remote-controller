import Foundation
import MacSupport

do {
    guard geteuid() == 0 else { throw UnlockFailure.unavailable }
    let broker = try UnlockBroker(installation: UnlockInstallationRecord.load())
    broker.start()
    RunLoop.main.run()
} catch {
    fputs("Sofa Remote unlock helper unavailable.\n", stderr)
    exit(1)
}
