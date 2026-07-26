import Foundation

/// Stable, privacy-safe identity matching for system audio inputs. A suffix in
/// the OS display name can contain a per-device identifier, so callers only
/// expose the product label and never persist or log the full matched name.
enum ExternalMicrophoneProfile {
    static func isDJIMic2(displayName: String) -> Bool {
        let value = displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return hasProductPrefix(value, prefix: "dji-mic2")
            || hasProductPrefix(value, prefix: "dji mic2")
            || hasProductPrefix(value, prefix: "dji mic 2")
    }

    private static func hasProductPrefix(_ value: String, prefix: String) -> Bool {
        guard value.hasPrefix(prefix) else { return false }
        guard value.count > prefix.count else { return true }
        let boundary = value[value.index(value.startIndex, offsetBy: prefix.count)]
        return boundary == "-" || boundary == " " || boundary == "("
    }
}
