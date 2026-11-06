/// Optional session controls are independent of input and remote-unlock permission.
public enum SessionControlPolicy {
    public static func isControl(_ command: CommandName) -> Bool {
        switch command {
        case .sessionLock, .displayOff, .displayWake, .sessionLockAndDisplayOff: true
        default: false
        }
    }

    public static func allows(_ command: CommandName, state: RemoteState) -> Bool {
        let capabilities = state.capabilities ?? []
        switch command {
        case .sessionUnlock:
            return capabilities.contains(WireCapabilities.remoteUnlock)
                && state.sessionLocked == true && state.unlockAvailable == true
        case .sessionLock:
            return capabilities.contains(WireCapabilities.remoteLock)
                && state.sessionLocked == false
        case .displayOff:
            return capabilities.contains(WireCapabilities.displayPower)
                && state.sessionLocked != nil && state.displayAsleep == false
        case .displayWake:
            return capabilities.contains(WireCapabilities.displayPower)
                && state.sessionLocked != nil && state.displayAsleep == true
        case .sessionLockAndDisplayOff:
            return capabilities.contains(WireCapabilities.remoteLock)
                && capabilities.contains(WireCapabilities.displayPower)
                && state.sessionLocked != nil && state.displayAsleep != nil
                && !(state.sessionLocked == true && state.displayAsleep == true)
        default: return false
        }
    }
}
