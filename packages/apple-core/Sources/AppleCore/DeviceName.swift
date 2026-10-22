public enum DeviceName {
    /// Keeps a device name within the wire protocol's UTF-8 byte limit.
    public static func bounded(_ value: String, fallback: String = "iOS device") -> String {
        let safeFallback = boundedNonempty(fallback) ?? "Device"
        return boundedNonempty(value) ?? safeFallback
    }

    private static func boundedNonempty(_ value: String) -> String? {
        guard !value.isEmpty else { return nil }

        var result = ""
        var byteCount = 0

        for character in value {
            let characterBytes = character.utf8.count
            guard byteCount + characterBytes <= WireLimits.maximumDeviceNameBytes else {
                break
            }
            result.append(character)
            byteCount += characterBytes
        }

        // A single grapheme can be longer than the entire wire limit.
        return result.isEmpty ? nil : result
    }
}
