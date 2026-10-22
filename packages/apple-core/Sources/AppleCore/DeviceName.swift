public enum DeviceName {
    /// Keeps a device name within the wire protocol's UTF-8 byte limit.
    public static func bounded(_ value: String) -> String {
        let source = value.isEmpty ? "iOS device" : value
        var result = ""
        var byteCount = 0

        for character in source {
            let characterBytes = character.utf8.count
            guard byteCount + characterBytes <= WireLimits.maximumDeviceNameBytes else {
                break
            }
            result.append(character)
            byteCount += characterBytes
        }

        // A single grapheme can be longer than the entire wire limit.
        return result.isEmpty ? "iOS device" : result
    }
}
