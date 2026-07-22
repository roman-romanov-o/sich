import AppKit

/// Why a light/dark flip used to leave half the app painted for the old theme.
///
/// A dynamic `NSColor` (``BoardTheme/dynamic(dark:light:)``) resolves *at draw time*,
/// which is why themed **text** follows the system on its own — `NSTextField.textColor`
/// holds the dynamic colour and AppKit re-resolves it every repaint. A `CALayer` can't
/// do that: `.cgColor` resolves the colour once, against whatever appearance happens to
/// be current on that line, and the layer keeps that frozen value forever. Nearly every
/// surface here is a layer-backed fill, so on a flip the text re-coloured and the
/// backgrounds did not — the drill-in sidebar stayed light paper under a dark terminal.
///
/// The fix is to keep the source `NSColor` next to the layer and re-resolve it from one
/// place. Assign ``themedBackground``/``themedBorder``/``themedShadow`` instead of
/// writing `layer?.backgroundColor` & co. directly, and the colour is both applied now
/// *and* remembered for the next flip. ``ThemedRootView`` drives the re-resolve for a
/// whole window, so no individual view carries theme bookkeeping of its own.
///
/// A view that paints raw sublayers instead of a layer fill can't be reached this way;
/// it adopts ``ThemeReapplying`` to get the same nudge.
@MainActor
extension NSView {
    /// The layer fill, remembered so it can be re-resolved on a light/dark flip.
    var themedBackground: NSColor? {
        get { themedColors?.background }
        set { themedColors(creating: true)?.background = newValue; applyThemedColors() }
    }

    /// The layer border colour. Setting a border colour does not set `borderWidth` —
    /// that's static geometry, and stays the caller's business.
    var themedBorder: NSColor? {
        get { themedColors?.border }
        set { themedColors(creating: true)?.border = newValue; applyThemedColors() }
    }

    /// The layer shadow colour. As with the border, the shadow's opacity/radius/offset
    /// are geometry and stay the caller's.
    var themedShadow: NSColor? {
        get { themedColors?.shadow }
        set { themedColors(creating: true)?.shadow = newValue; applyThemedColors() }
    }

    /// Re-resolve every themed colour in this view and its subtree. Cheap: a view with no
    /// themed colours registered is skipped, and the walk only touches layers this file
    /// put colours on.
    func reapplyThemedColors() {
        reapplyThemedColors(under: effectiveAppearance)
    }

    /// The appearance is handed down rather than read from each view, because mid-flip it
    /// can't be read: when the root is told its effective appearance changed, AppKit has
    /// not reached the descendants yet, so their `effectiveAppearance` is still the side
    /// we just left. A walk that trusted it painted the whole window one flip behind —
    /// light while dark, dark while light. The root's own appearance is current by the
    /// time its hook runs, so that's the one worth propagating.
    private func reapplyThemedColors(under inherited: NSAppearance) {
        // A view that pins its own `appearance` opts out of the inherited one, exactly as
        // `effectiveAppearance` would have it — and its subtree inherits that instead.
        let live = appearance ?? inherited
        applyThemedColors(under: live)
        (self as? ThemeReapplying)?.reapplyTheme(under: live)
        for subview in subviews { subview.reapplyThemedColors(under: live) }
    }

    private func applyThemedColors() {
        applyThemedColors(under: effectiveAppearance)
    }

    /// Resolve the remembered colours and push them into the layer.
    /// `performAsCurrentDrawingAppearance` is what makes `.cgColor` pick the right side of
    /// a dynamic colour — without it the resolve silently uses whatever appearance the
    /// calling thread last had current.
    private func applyThemedColors(under appearance: NSAppearance) {
        guard let colors = themedColors else { return }
        wantsLayer = true
        guard let layer else { return }
        appearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = colors.background?.cgColor
            layer.borderColor = colors.border?.cgColor
            if let shadow = colors.shadow { layer.shadowColor = shadow.cgColor }
        }
    }

    private func themedColors(creating: Bool) -> ThemedColors? {
        if let existing = themedColors { return existing }
        guard creating else { return nil }
        let box = ThemedColors()
        objc_setAssociatedObject(self, themedColorsKey, box, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return box
    }

    private var themedColors: ThemedColors? {
        objc_getAssociatedObject(self, themedColorsKey) as? ThemedColors
    }
}

/// A view whose theming lives somewhere ``NSView/themedBackground`` can't reach —
/// raw sublayers, or an attributed string it builds itself — and so has to re-apply it
/// by hand when the appearance flips. ``NSView/reapplyThemedColors()`` calls this as it
/// walks, so adopters need no appearance hook of their own.
@MainActor
protocol ThemeReapplying: AnyObject {
    /// Repaint from ``BoardTheme``. Called on every light/dark flip; must be safe to call
    /// repeatedly and before any content arrives.
    ///
    /// - Parameter appearance: resolve against this, and *not* against the receiver's
    ///   `effectiveAppearance` — mid-flip that's still the side we just left.
    func reapplyTheme(under appearance: NSAppearance)
}

/// The window content view every surface hangs under. AppKit dispatches
/// `viewDidChangeEffectiveAppearance` down the tree on a system light/dark switch, and
/// this turns that one event into a re-resolve of the whole window — the single hook
/// that replaced a per-view `viewDidChangeEffectiveAppearance` in every class.
@MainActor
final class ThemedRootView: NSView {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        reapplyThemedColors()
    }
}

/// The remembered colours for one view. A class (not a struct) so it can be stored as
/// an associated object and mutated in place; `ThemedRole`-keyed dictionaries wouldn't
/// survive the bridge to `AnyObject`.
private final class ThemedColors {
    var background: NSColor?
    var border: NSColor?
    var shadow: NSColor?
}

/// A stable, unique address to key the associated object on. Allocated once and never
/// freed — the standard way to avoid `&someGlobalVar`, which forms a pointer to storage
/// Swift makes no lifetime promises about. `nonisolated(unsafe)` is accurate rather than
/// a silencer: the pointer is read-only after init and only its *address* is ever used.
nonisolated(unsafe) private let themedColorsKey = UnsafeRawPointer(
    UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1))
