import Foundation

/// Release tags are `v0.8.0`, the bundle says `0.8.0`. Compared number by
/// number, so `0.10.0` is newer than `0.9.0` — a plain string compare says no.
public enum AppVersion {
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        strip(candidate).compare(strip(current), options: .numeric) == .orderedDescending
    }

    public static func strip(_ tag: String) -> String {
        tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }
}
