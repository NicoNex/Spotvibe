import SwiftUI

/// The silhouette of a hanging drop: a bead at the top, a bulb below, and a neck between
/// them whose waist narrows until it pinches off.
///
/// This exists because `glassEffectUnion` cannot draw it. The union is a proximity blend
/// between two shapes — it decides *whether* they read as one body, not what the join
/// between them looks like. Its bridge is roughly as wide as the smaller shape and it
/// simply stops being drawn once the two are far enough apart, so no amount of shrinking
/// one end or widening the merge distance produces a filament that thins to nothing. A
/// real pendant drop necks down to a thread and snaps, and that profile has to be authored.
///
/// `glassEffect(_:in:)` takes any `Shape`, so the system renders its material — rim,
/// refraction and all — inside whatever outline this returns.
struct PendantDrop: Shape {
    /// Radius of the bead still hanging at the top.
    var topRadius: CGFloat
    /// Radius of the bulb that has gathered at the bottom.
    var bottomRadius: CGFloat
    /// Half-width of the neck at its narrowest. Zero is the instant it pinches off.
    var waist: CGFloat
    /// 0 pulls the neck's walls straight, 1 lets them bow all the way in to the waist.
    /// Higher values read as more surface tension: a longer, more concave filament.
    var tension: CGFloat = 0.55

    /// All three measurements interpolate together, so the whole silhouette animates as one.
    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(topRadius, AnimatablePair(bottomRadius, waist)) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second.first
            waist = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let cx = rect.midX
        let top = CGPoint(x: cx, y: rect.minY + topRadius)
        let bottom = CGPoint(x: cx, y: rect.maxY - bottomRadius)

        // Degenerate cases: too short to hold a neck at all, so draw the bulb alone.
        guard bottom.y > top.y else {
            return Path(ellipseIn: CGRect(x: cx - bottomRadius, y: rect.maxY - bottomRadius * 2,
                                          width: bottomRadius * 2, height: bottomRadius * 2))
        }

        let waistY = (top.y + bottom.y) / 2
        // Never exactly zero: a path that closes on itself at a point renders unpredictably,
        // and a hair's width is indistinguishable from a clean break on screen.
        let halfWidth = max(waist, 0.5)
        let upperRun = (waistY - top.y) * tension
        let lowerRun = (bottom.y - waistY) * tension

        var path = Path()
        // Left side of the bead, over the top, to its right side.
        path.addArc(center: top, radius: topRadius,
                    startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
        // Down the right wall of the neck, bowing in to the waist and back out to the bulb.
        path.addQuadCurve(to: CGPoint(x: cx + halfWidth, y: waistY),
                          control: CGPoint(x: cx + topRadius, y: top.y + upperRun))
        path.addQuadCurve(to: CGPoint(x: cx + bottomRadius, y: bottom.y),
                          control: CGPoint(x: cx + bottomRadius, y: bottom.y - lowerRun))
        // Right side of the bulb, under the bottom, to its left side.
        path.addArc(center: bottom, radius: bottomRadius,
                    startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
        // Back up the left wall, mirrored.
        path.addQuadCurve(to: CGPoint(x: cx - halfWidth, y: waistY),
                          control: CGPoint(x: cx - bottomRadius, y: bottom.y - lowerRun))
        path.addQuadCurve(to: CGPoint(x: cx - topRadius, y: top.y),
                          control: CGPoint(x: cx - topRadius, y: top.y + upperRun))
        path.closeSubpath()
        return path
    }
}
