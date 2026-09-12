import AppKit

/// Which face the menu-bar glyph should wear. Derived from `Engine.State` (see
/// `AppModel.iconState`), one case per distinct status.
enum PancakeIconState {
    case nominal    // running, playing to an output — the short stack with a pat of butter
    case muted      // running, but no output connected — the stack with a slash
    case degraded   // couldn't build the routing — the stack crowned with an exclamation
    case stopped    // engine stopped — an outline-only stack
}

/// The app's face: a short stack of pancakes drawn by hand as a monochrome menu-bar
/// template image. Everything is one colour, so the gaps between pancakes and the
/// butter's edge are cut as negative space (thin transparent grooves) and macOS tints
/// the result black on light menu bars / white on dark ones.
enum PancakeIcon {
    /// A menu-bar-sized template image for `state`. `isTemplate` lets AppKit tint it.
    static func image(for state: PancakeIconState, pointSize: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            draw(in: ctx, boxSize: pointSize, tint: .black, state: state)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "pancake"
        return image
    }

    /// Whole-glyph tilt, in degrees. Kept at 0 so the stack sits upright on its axis.
    private static let tiltDegrees: CGFloat = 0

    /// How much of the box the glyph fills. >1 enlarges it about the centre; kept
    /// safely under the point where the tilted silhouette would clip the bounds.
    private static let glyphScale: CGFloat = 1.15

    /// Draw the glyph into `ctx`, filling ink with `tint` and carving negative space
    /// with the `.clear` blend. Design space is a 100x100 box (y-up); all geometry
    /// scales from `boxSize`.
    static func draw(in ctx: CGContext, boxSize: CGFloat, tint: CGColor, state: PancakeIconState) {
        let s = boxSize / 100.0
        // Enlarge and tilt the whole glyph about the centre of the box.
        let c = 50 * s
        ctx.translateBy(x: c, y: c)
        ctx.rotate(by: tiltDegrees * .pi / 180)
        ctx.scaleBy(x: glyphScale, y: glyphScale)
        ctx.translateBy(x: -c, y: -c)
        func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }
        func ellipseRect(cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat) -> CGRect {
            CGRect(x: (cx - rx) * s, y: (cy - ry) * s, width: 2 * rx * s, height: 2 * ry * s)
        }

        // Three pancakes (cx, cy, rx, ry) — bottom widest, gentle taper upward so the
        // stack reads as a low-angle short stack rather than a cone.
        let cx: CGFloat = 50
        let bottom = (cy: CGFloat(32), rx: CGFloat(34), ry: CGFloat(9.5))
        let mid    = (cy: CGFloat(46), rx: CGFloat(32), ry: CGFloat(9.0))
        let top    = (cy: CGFloat(59.5), rx: CGFloat(30), ry: CGFloat(8.5))

        // Butter pat: a small flat rounded square sitting on the crown of the top pancake.
        let butter = CGRect(x: (cx - 8.5) * s, y: 63 * s, width: 17 * s, height: 13 * s)
        let butterCorner = 2.5 * s

        let sepWidth = 4.5 * s       // negative-space groove between pancakes / butter base
        let outlineWidth = 5.0 * s   // stroke weight for the "stopped" outline-only look
        let fullRect = CGRect(x: 0, y: 0, width: boxSize, height: boxSize)

        let bottomE = ellipseRect(cx: cx, cy: bottom.cy, rx: bottom.rx, ry: bottom.ry)
        let midE    = ellipseRect(cx: cx, cy: mid.cy, rx: mid.rx, ry: mid.ry)
        let topE    = ellipseRect(cx: cx, cy: top.cy, rx: top.rx, ry: top.ry)

        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)

        // Stroke `path` while clipping away everything inside `holes` (even-odd), so a
        // lower layer's outline stops cleanly where the layer above it sits on top.
        func strokeClippedOutside(_ path: CGPath, holes: [CGRect]) {
            ctx.saveGState()
            if !holes.isEmpty {
                let clip = CGMutablePath()
                clip.addRect(fullRect)
                for h in holes { clip.addEllipse(in: h) }
                ctx.addPath(clip)
                ctx.clip(using: .evenOdd)
            }
            ctx.addPath(path)
            ctx.strokePath()
            ctx.restoreGState()
        }

        if state == .stopped {
            // Outline-only nested stack: line art reads as "idle / off".
            ctx.setStrokeColor(tint)
            ctx.setLineWidth(outlineWidth)
            strokeClippedOutside(CGPath(ellipseIn: topE, transform: nil), holes: [])
            strokeClippedOutside(CGPath(ellipseIn: midE, transform: nil), holes: [topE])
            strokeClippedOutside(CGPath(ellipseIn: bottomE, transform: nil), holes: [topE, midE])
            strokeClippedOutside(CGPath(roundedRect: butter, cornerWidth: butterCorner, cornerHeight: butterCorner, transform: nil), holes: [topE])
            return
        }

        // --- Solid states (nominal / muted / degraded) ---

        // 1. Fill the silhouette: three overlapping ellipses (+ the butter block, except
        //    in the degraded state where an exclamation mark takes the crown instead).
        ctx.setFillColor(tint)
        ctx.fillEllipse(in: bottomE)
        ctx.fillEllipse(in: midE)
        ctx.fillEllipse(in: topE)
        if state != .degraded {
            ctx.addPath(CGPath(roundedRect: butter, cornerWidth: butterCorner, cornerHeight: butterCorner, transform: nil))
            ctx.fillPath()
        }

        // 2. Carve negative-space grooves: the front lip of each upper pancake, and the
        //    base of the butter, so the layers separate in a single-colour template.
        ctx.setBlendMode(.clear)
        ctx.setLineWidth(sepWidth)
        // Front lip of the top pancake (its lower arc).
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: 0, width: boxSize, height: top.cy * s))
        ctx.strokeEllipse(in: topE)
        ctx.restoreGState()
        // Front lip of the mid pancake.
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: 0, width: boxSize, height: mid.cy * s))
        ctx.strokeEllipse(in: midE)
        ctx.restoreGState()
        // Butter outline groove (separates the pat from the top pancake where they overlap).
        if state != .degraded {
            ctx.addPath(CGPath(roundedRect: butter, cornerWidth: butterCorner, cornerHeight: butterCorner, transform: nil))
            ctx.strokePath()
        }
        ctx.setBlendMode(.normal)

        // 3. State modifiers.
        switch state {
        case .muted:
            // A slash across the glyph: a wide clear band with a thinner ink line inside
            // it, so it reads on both the filled stack and the empty margins.
            let a = P(17, 83), b = P(83, 17)
            ctx.setBlendMode(.clear)
            ctx.setLineWidth(16 * s)
            ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
            ctx.setBlendMode(.normal)
            ctx.setStrokeColor(tint)
            ctx.setLineWidth(8 * s)
            ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()

        case .degraded:
            // A bold exclamation mark crowning the stack in place of the butter — the
            // clearest "something's wrong" cue that survives 18pt. Carve a clear pocket
            // so it separates from the top pancake, then draw the mark in ink.
            ctx.setBlendMode(.clear)
            let pocket = CGRect(x: (cx - 7) * s, y: 52 * s, width: 14 * s, height: 34 * s)
            ctx.addPath(CGPath(roundedRect: pocket, cornerWidth: 7 * s, cornerHeight: 7 * s, transform: nil))
            ctx.fillPath()
            ctx.setBlendMode(.normal)
            ctx.setFillColor(tint)
            // Bar.
            let bar = CGRect(x: (cx - 4) * s, y: 64 * s, width: 8 * s, height: 18 * s)
            ctx.addPath(CGPath(roundedRect: bar, cornerWidth: 4 * s, cornerHeight: 4 * s, transform: nil))
            ctx.fillPath()
            // Dot.
            ctx.fillEllipse(in: CGRect(x: (cx - 4) * s, y: 54 * s, width: 8 * s, height: 8 * s))

        case .nominal, .stopped:
            break
        }
    }
}
