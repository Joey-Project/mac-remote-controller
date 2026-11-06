import dnssd

/// Network wake is optional. Unsupported flags must not block ordinary connections.
enum BonjourResolveAttempt {
    static func start(
        wakeOnResolve: Bool, interfaceIndex: UInt32,
        attempt: (DNSServiceFlags) -> DNSServiceErrorType
    ) -> (status: DNSServiceErrorType, usedWake: Bool) {
        // Wake requires a concrete interface; reserved interface selectors are rejected.
        let useWake =
            wakeOnResolve && interfaceIndex > 0
            && interfaceIndex < kDNSServiceInterfaceIndexBLE
        let status = attempt(useWake ? DNSServiceFlags(kDNSServiceFlagsWakeOnResolve) : 0)
        let unsupported = [
            kDNSServiceErr_BadParam, kDNSServiceErr_BadFlags, kDNSServiceErr_Unsupported
        ]
        if useWake, unsupported.contains(Int(status)) {
            return (attempt(0), false)
        }
        return (status, useWake)
    }
}
