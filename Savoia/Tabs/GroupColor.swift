import Foundation

/// A tab group's colour in OKLCH, where two colours mix the way paint does: red and yellow give
/// orange, not the brown an RGB average gives.
nonisolated struct GroupColor: Sendable, Equatable {
    var lightness: Double
    var chroma: Double
    /// Degrees.
    var hue: Double

    /// The three primaries first, so the colours between the first three groups are their mixes.
    static let palette: [GroupColor] = [
        GroupColor(lightness: 0.60, chroma: 0.19, hue: 258), // blue
        GroupColor(lightness: 0.62, chroma: 0.21, hue: 27),  // red
        GroupColor(lightness: 0.84, chroma: 0.17, hue: 88),  // yellow
        GroupColor(lightness: 0.68, chroma: 0.17, hue: 148), // green
        GroupColor(lightness: 0.56, chroma: 0.20, hue: 300), // purple
        GroupColor(lightness: 0.72, chroma: 0.12, hue: 205), // teal
        GroupColor(lightness: 0.68, chroma: 0.19, hue: 350), // pink
    ]

    /// The first palette entry nobody has, else the one fewest have.
    static func free(among used: [Int]) -> Int {
        let counts = palette.indices.map { index in used.filter { $0 == index }.count }
        return counts.indices.min { counts[$0] < counts[$1] } ?? 0
    }

    /// `weight` 0 is this colour, 1 is `other`; the hue goes the short way round.
    func mixed(with other: GroupColor, by weight: Double) -> GroupColor {
        let w = min(1, max(0, weight))
        var delta = (other.hue - hue).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        let hue = (self.hue + delta * w + 360).truncatingRemainder(dividingBy: 360)
        return GroupColor(lightness: lightness + (other.lightness - lightness) * w,
                          chroma: chroma + (other.chroma - chroma) * w, hue: hue)
    }

    /// Towards a pale neutral: the colour of something almost in the group.
    func faded(by weight: Double) -> GroupColor {
        let w = min(1, max(0, weight))
        return GroupColor(lightness: lightness + (0.8 - lightness) * w, chroma: chroma * (1 - w), hue: hue)
    }

    /// Light enough that dark text reads better on it than white.
    var isLight: Bool { lightness > 0.72 }

    /// Gamma-encoded sRGB, the chroma cut back until the colour exists there.
    var srgb: (red: Double, green: Double, blue: Double) {
        var low = 0.0, high = chroma
        var linear = Self.linear(lightness, chroma, hue)
        if !Self.inGamut(linear) {
            for _ in 0..<20 {
                let mid = (low + high) / 2
                if Self.inGamut(Self.linear(lightness, mid, hue)) { low = mid } else { high = mid }
            }
            linear = Self.linear(lightness, low, hue)
        }
        func encode(_ x: Double) -> Double {
            let x = min(1, max(0, x))
            return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
        }
        return (encode(linear.0), encode(linear.1), encode(linear.2))
    }

    private static func inGamut(_ c: (Double, Double, Double)) -> Bool {
        let e = 1e-4
        return c.0 >= -e && c.0 <= 1 + e && c.1 >= -e && c.1 <= 1 + e && c.2 >= -e && c.2 <= 1 + e
    }

    /// Björn Ottosson's OKLab to linear sRGB.
    private static func linear(_ l: Double, _ c: Double, _ h: Double) -> (Double, Double, Double) {
        let a = c * cos(h * .pi / 180), b = c * sin(h * .pi / 180)
        let l_ = l + 0.3963377774 * a + 0.2158037573 * b
        let m_ = l - 0.1055613458 * a - 0.0638541728 * b
        let s_ = l - 0.0894841775 * a - 1.2914855480 * b
        let (L, M, S) = (l_ * l_ * l_, m_ * m_ * m_, s_ * s_ * s_)
        return (4.0767416621 * L - 3.3077115913 * M + 0.2309699292 * S,
                -1.2684380046 * L + 2.6097574011 * M - 0.3413193965 * S,
                -0.0041960863 * L - 0.7034186147 * M + 1.7076147010 * S)
    }
}
