import Foundation

/// Minimum-contrast enforcement for terminal text — the same idea as Ghostty's
/// `minimum-contrast` config. Shell autosuggestions (zsh-autosuggest, fish) and any
/// SGR-faint text arrive here as an already-resolved dim grey RGB; on a dark
/// background that grey is legible-in-theory but hard to *spot*. Rather than
/// special-casing "is this an autosuggestion" (we only get resolved colours, not the
/// palette index or faint bit), we lift ANY foreground whose contrast against its
/// own background falls below a floor. Text that is already legible is left exactly
/// as-is, so normal output keeps its theme colours untouched.
public enum ContrastColor {
    /// The WCAG relative luminance of an sRGB colour (0…1). Channels are gamma-
    /// expanded to linear light before the Rec.709 weighting.
    public static func relativeLuminance(_ color: RGB) -> Double {
        func linear(_ raw: UInt8) -> Double {
            let s = Double(raw) / 255
            return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.r) + 0.7152 * linear(color.g) + 0.0722 * linear(color.b)
    }

    /// The WCAG contrast ratio between two colours (1…21), order-independent.
    public static func contrastRatio(_ a: RGB, _ b: RGB) -> Double {
        let la = relativeLuminance(a)
        let lb = relativeLuminance(b)
        let (hi, lo) = la > lb ? (la, lb) : (lb, la)
        return (hi + 0.05) / (lo + 0.05)
    }

    /// Return `fg` unchanged if it already meets `minimumRatio` against `bg`; else
    /// blend it toward whichever of black/white contrasts more with `bg` — just far
    /// enough to clear the floor, so a dim suggestion becomes visible without being
    /// slammed to full white (which would read as normal, not a hint).
    public static func adjusted(
        _ fg: RGB, against bg: RGB, minimumRatio: Double
    ) -> RGB {
        guard contrastRatio(fg, bg) < minimumRatio else { return fg }
        let target = relativeLuminance(.white) - relativeLuminance(bg)
            > relativeLuminance(bg) - relativeLuminance(.black) ? RGB.white : RGB.black
        return blendToFloor(fg, target: target, bg: bg, minimumRatio: minimumRatio)
    }

    /// Binary-search the blend fraction `t` (fg → target) for the smallest lift that
    /// clears `minimumRatio`. Contrast is monotonic along fg→(black|white), so a
    /// bisection converges; if even the full target can't reach the floor (a mid-grey
    /// bg), `t = 1` gives the best achievable.
    private static func blendToFloor(
        _ fg: RGB, target: RGB, bg: RGB, minimumRatio: Double
    ) -> RGB {
        if contrastRatio(target, bg) < minimumRatio { return target }
        var lo = 0.0
        var hi = 1.0
        for _ in 0..<20 {
            let mid = (lo + hi) / 2
            if contrastRatio(fg.blended(toward: target, fraction: mid), bg) >= minimumRatio {
                hi = mid
            } else {
                lo = mid
            }
        }
        return fg.blended(toward: target, fraction: hi)
    }
}

extension RGB {
    public static let white = RGB(r: 255, g: 255, b: 255)
    public static let black = RGB(r: 0, g: 0, b: 0)

    /// Linear per-channel blend `self → other` by `fraction` (0 = self, 1 = other).
    public func blended(toward other: RGB, fraction: Double) -> RGB {
        func mix(_ a: UInt8, _ b: UInt8) -> UInt8 {
            UInt8((Double(a) + (Double(b) - Double(a)) * fraction).rounded())
        }
        return RGB(r: mix(r, other.r), g: mix(g, other.g), b: mix(b, other.b))
    }
}
