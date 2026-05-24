import SwiftUI

/// Color palette matching the Claude Design brief. Values are sRGB
/// approximations of the designer's oklch values — they render identically
/// on sRGB displays and close-enough on P3. Each role has a light/dark pair
/// that SwiftUI swaps automatically via `@Environment(\.colorScheme)`.
enum Theme {
    /// Quorra's Tron-inspired cyan accent.
    /// Design source: `oklch(68% 0.14 220)` / `oklch(78% 0.16 220)`.
    static let accent = Color(light: Color(red: 0.235, green: 0.576, blue: 0.749),
                              dark:  Color(red: 0.373, green: 0.725, blue: 0.871))

    /// Muted amber for non-blocking warnings (non-standard folder, stale state).
    /// Design source: `oklch(72% 0.16 70)` / `oklch(82% 0.16 70)`.
    static let warn = Color(light: Color(red: 0.847, green: 0.580, blue: 0.314),
                            dark:  Color(red: 0.941, green: 0.690, blue: 0.439))

    /// Muted red for hard failures (access denied, bookmark corruption).
    /// Design source: `oklch(58% 0.18 25)` / `oklch(70% 0.20 25)`.
    static let danger = Color(light: Color(red: 0.769, green: 0.322, blue: 0.290),
                              dark:  Color(red: 0.910, green: 0.471, blue: 0.376))

    // MARK: - Session badge palette

    /// Categorical hues for the `via <session>` badge, assigned deterministically per
    /// SSO-session name. Drawn from the cool→magenta arc to stay clear of the semantic
    /// colors (green ≈150, red ≈25, amber ≈70) and the cyan accent (≈220), so a badge
    /// never reads as a status signal. Long-term / "other" profiles use no hue (see
    /// `ViaBadge`) — color means "which SSO org".
    /// Design sources: `oklch(68% 0.13 H)` / `oklch(78% 0.14 H)`.
    static let badgeIndigo  = Color(light: Color(red: 0.442, green: 0.586, blue: 0.912),
                                    dark:  Color(red: 0.546, green: 0.708, blue: 1.000))  // H265
    static let badgeBlue    = Color(light: Color(red: 0.329, green: 0.615, blue: 0.898),
                                    dark:  Color(red: 0.426, green: 0.741, blue: 1.000))  // H250
    static let badgePurple  = Color(light: Color(red: 0.595, green: 0.537, blue: 0.888),
                                    dark:  Color(red: 0.716, green: 0.654, blue: 1.000))  // H290
    static let badgeViolet  = Color(light: Color(red: 0.693, green: 0.503, blue: 0.831),
                                    dark:  Color(red: 0.827, green: 0.615, blue: 0.981))  // H310
    static let badgeMagenta = Color(light: Color(red: 0.788, green: 0.469, blue: 0.721),
                                    dark:  Color(red: 0.933, green: 0.579, blue: 0.858))  // H335
    static let badgePink    = Color(light: Color(red: 0.828, green: 0.457, blue: 0.641),
                                    dark:  Color(red: 0.978, green: 0.565, blue: 0.768))  // H350

    /// Palette ordered for deterministic assignment.
    static let sessionBadgePalette: [Color] = [badgeIndigo, badgeBlue, badgePurple, badgeViolet, badgeMagenta, badgePink]

    /// Stable per-session hue. Uses FNV-1a over the UTF-8 name so the mapping is identical
    /// across launches — Swift's `Hasher` is per-process salted and would not be stable.
    static func sessionBadgeColor(for sessionName: String) -> Color {
        sessionBadgePalette[fnv1aIndex(sessionName, modulo: sessionBadgePalette.count)]
    }
}

/// FNV-1a over UTF-8, reduced into `0..<modulo`. Deterministic across launches.
private func fnv1aIndex(_ string: String, modulo: Int) -> Int {
    var hash: UInt64 = 1469598103934665603
    for byte in string.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 1099511628211
    }
    return Int(hash % UInt64(modulo))
}

private extension Color {
    /// Creates a `Color` that resolves to `light` in light mode and `dark` in dark mode.
    init(light: Color, dark: Color) {
        self = Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastVibrantDark]) != nil
                ? NSColor(dark)
                : NSColor(light)
        })
    }
}
