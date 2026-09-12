import AppKit
import Foundation
import SwiftUI

/// Blends between two colours through OKLCH (a perceptual space), sweeping hue the short way, so a
/// wire stays vivid across the whole colour wheel instead of desaturating to grey in the middle the
/// way a straight sRGB interpolation does (tap-green → mic-purple was the worst offender).
///
/// We can't use Mixbox — it's CC BY-NC, incompatible with this repo's GPL-3.0 — and OKLCH is just
/// colour-space maths (after Björn Ottosson, 2020), so it's clean. The result is baked into a handful
/// of gradient stops; SwiftUI still interpolates linearly between adjacent stops, but ~13 of them
/// track the curved path closely.
enum ColorBlend {
    /// A gradient from `c0` to `c1` interpolated in OKLCH. Drop-in for `Gradient(colors: [c0, c1])`.
    static func oklch(_ c0: Color, _ c1: Color, stops: Int = 13) -> Gradient {
        let a = oklab(c0), b = oklab(c1)
        let cA = hypot(a.1, a.2), cB = hypot(b.1, b.2)
        let hA = atan2(a.2, a.1)
        var dh = atan2(b.2, b.1) - hA
        if dh > .pi { dh -= 2 * .pi }
        if dh < -.pi { dh += 2 * .pi }

        let n = max(2, stops)
        var out: [Gradient.Stop] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let t = Double(i) / Double(n - 1)
            let L = a.0 + (b.0 - a.0) * t
            let c = cA + (cB - cA) * t
            let h = hA + dh * t
            let rgb = srgb((L, cos(h) * c, sin(h) * c))
            out.append(.init(color: Color(.sRGB, red: rgb.0, green: rgb.1, blue: rgb.2, opacity: 1), location: t))
        }
        return Gradient(stops: out)
    }

    // MARK: sRGB ↔ OKLab

    private static func rgba(_ color: Color) -> (Double, Double, Double) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        return (Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent))
    }

    private static func toLinear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    private static func toGamma(_ c: Double) -> Double {
        let x = min(1, max(0, c))
        return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
    }
    private static func cube(_ x: Double) -> Double { x * x * x }

    private static func oklab(_ color: Color) -> (Double, Double, Double) {
        let (r0, g0, b0) = rgba(color)
        let r = toLinear(r0), g = toLinear(g0), b = toLinear(b0)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    private static func srgb(_ lab: (Double, Double, Double)) -> (Double, Double, Double) {
        let (L, a, b) = lab
        let l = cube(L + 0.3963377774 * a + 0.2158037573 * b)
        let m = cube(L - 0.1055613458 * a - 0.0638541728 * b)
        let s = cube(L - 0.0894841775 * a - 1.2914855480 * b)
        return (toGamma( 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
                toGamma(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
                toGamma(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s))
    }
}
