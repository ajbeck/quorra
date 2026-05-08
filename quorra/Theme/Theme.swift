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
