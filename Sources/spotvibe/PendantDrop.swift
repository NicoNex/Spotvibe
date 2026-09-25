import SwiftUI

/// The silhouette of a hanging drop: a bulb of liquid below, the anchor it hangs from
/// above, and a filament between them that necks down and pinches off.
///
/// This exists because `glassEffectUnion` cannot draw it. The union is a proximity blend
/// between two shapes — it decides *whether* they read as one body, not what the join
/// between them looks like. Its bridge is roughly as wide as the smaller shape and it
/// simply stops being drawn once the two are far enough apart, so no amount of shrinking
/// one end or widening the merge distance produces a filament that thins to nothing.
///
/// `glassEffect(_:in:)` takes any `Shape`, so the system renders its own material — rim,
/// refraction and all — inside whatever outline this returns.
struct PendantDrop: Shape {
    /// Half-width of the anchor the drop hangs from, at the very top.
    var topRadius: CGFloat
    /// Radius of the bulb that has gathered at the bottom.
    var bottomRadius: CGFloat
    /// Half-width of the filament at its narrowest. Zero is the instant it pinches off.
    var waist: CGFloat

    /// Where along the neck the pinch sits, 0 at the anchor and 1 at the bulb. Real drops
    /// neck close to what they hang from, not halfway down.
    private let pinchAt: CGFloat = 0.3
    /// Half-width where the filament meets the bulb, as a fraction of the bulb's radius.
    /// Well under 1 so the two meet in a concave sweep instead of a cone.
    private let footFraction: CGFloat = 0.42
    /// Samples along the profile. The outline is built from the width function directly —
    /// two quadratic curves could not hold a shape that is concave on both sides of a
    /// pinch, and bowed outwards into a funnel instead.
    private let samples = 28

    /// All three measurements interpolate together, so the whole silhouette animates as one.
    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(topRadius, AnimatablePair(bottomRadius, waist)) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second.first
            waist = newValue.second.second
        }
    }

    /// Half-width of the filament at `t` along its length. Quadratic on both sides of the
    /// pinch, so the walls curve inwards into the waist and back out to the bulb — the
    /// concave profile that reads as surface tension rather than a funnel.
    private func halfWidth(at t: CGFloat, foot: CGFloat) -> CGFloat {
        if t <= pinchAt {
            let k = 1 - t / pinchAt
            return waist + (topRadius - waist) * k * k
        }
        let k = (t - pinchAt) / (1 - pinchAt)
        return waist + (foot - waist) * k * k
    }

    func path(in rect: CGRect) -> Path {
        let cx = rect.midX
        let bulbCentre = CGPoint(x: cx, y: rect.maxY - bottomRadius)
        let bulb = CGRect(x: cx - bottomRadius, y: bulbCentre.y - bottomRadius,
                          width: bottomRadius * 2, height: bottomRadius * 2)

        var path = Path()
        path.addEllipse(in: bulb)

        // Where the filament meets the bulb: on the sphere, at the height whose half-width
        // is `foot`, so the neck lands ON the surface rather than floating above it.
        let foot = bottomRadius * footFraction
        let drop = (bottomRadius * bottomRadius - foot * foot).squareRoot()
        let neckTop = rect.minY
        let neckFoot = bulbCentre.y - drop

        // Nothing left to draw a neck in: the bulb alone is the whole drop.
        guard neckFoot > neckTop + 1 else { return path }

        var right: [CGPoint] = []
        var left: [CGPoint] = []
        for i in 0 ... samples {
            let t = CGFloat(i) / CGFloat(samples)
            let y = neckTop + (neckFoot - neckTop) * t
            let w = halfWidth(at: t, foot: foot)
            right.append(CGPoint(x: cx + w, y: y))
            left.append(CGPoint(x: cx - w, y: y))
        }

        path.move(to: right[0])
        for point in right.dropFirst() { path.addLine(to: point) }
        for point in left.reversed() { path.addLine(to: point) }
        path.closeSubpath()
        return path
    }
}
