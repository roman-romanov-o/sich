import Testing

@testable import SichCore

/// The minimum-contrast mechanism behind "terminal suggestions easier to spot".
/// The *machine-verifiable* half is the contrast math and the monotonic lift: a dim
/// grey on a dark background must come out meeting the floor, while already-legible
/// text must be returned byte-for-byte unchanged. The final on-screen look is a
/// visual concern the terminal surface owns and a human signs off.
@Suite("Terminal minimum-contrast")
struct ContrastColorTests {

    private let darkBg = RGB(r: 0x1e, g: 0x1e, b: 0x1e)     // typical terminal bg
    private let suggestionGrey = RGB(r: 0x58, g: 0x58, b: 0x58)  // zsh-autosuggest fg=8-ish

    @Test("a dim autosuggestion grey on a dark bg is lifted to meet the floor")
    func dimGreyIsLifted() {
        let floor = 4.5
        #expect(ContrastColor.contrastRatio(suggestionGrey, darkBg) < floor)  // starts illegible
        let fixed = ContrastColor.adjusted(suggestionGrey, against: darkBg, minimumRatio: floor)
        // Meets the floor now (small epsilon for the 20-step bisection landing point).
        #expect(ContrastColor.contrastRatio(fixed, darkBg) >= floor - 0.05)
        // …and it actually changed (was below, now at/above).
        #expect(fixed != suggestionGrey)
    }

    @Test("already-legible text is returned unchanged (identity, no theme drift)")
    func legibleTextUntouched() {
        let brightWhite = RGB(r: 0xff, g: 0xff, b: 0xff)
        let out = ContrastColor.adjusted(brightWhite, against: darkBg, minimumRatio: 4.5)
        #expect(out == brightWhite)
        // A mid-tone that already clears a modest floor is also untouched.
        let green = RGB(r: 0x2a, g: 0xa1, b: 0x98)
        #expect(ContrastColor.adjusted(green, against: darkBg, minimumRatio: 2.0) == green)
    }

    @Test("contrast ratio is symmetric and bounded 1…21")
    func ratioIsWellFormed() {
        #expect(ContrastColor.contrastRatio(.white, .black) > 20.9)
        #expect(ContrastColor.contrastRatio(darkBg, darkBg) == 1.0)
        // order-independent
        #expect(ContrastColor.contrastRatio(suggestionGrey, darkBg)
            == ContrastColor.contrastRatio(darkBg, suggestionGrey))
    }

    @Test("on a light background the lift goes darker, not brighter")
    func lightBgLiftsDarker() {
        let lightBg = RGB(r: 0xfa, g: 0xfa, b: 0xfa)
        let faintOnLight = RGB(r: 0xcf, g: 0xcf, b: 0xcf)   // barely-there grey on white
        let fixed = ContrastColor.adjusted(faintOnLight, against: lightBg, minimumRatio: 4.5)
        #expect(ContrastColor.relativeLuminance(fixed) < ContrastColor.relativeLuminance(faintOnLight))
        #expect(ContrastColor.contrastRatio(fixed, lightBg) >= 4.5 - 0.05)
    }

    @Test("a mid-grey bg where the floor is unreachable returns the best achievable")
    func unreachableFloorReturnsBest() {
        let midGrey = RGB(r: 0x80, g: 0x80, b: 0x80)
        // No colour reaches 21:1 against mid-grey — result must be black or white
        // (the extreme), never a crash or a worse-than-input colour.
        let out = ContrastColor.adjusted(midGrey, against: midGrey, minimumRatio: 21)
        #expect(out == .white || out == .black)
        #expect(ContrastColor.contrastRatio(out, midGrey)
            >= ContrastColor.contrastRatio(midGrey, midGrey))
    }
}
