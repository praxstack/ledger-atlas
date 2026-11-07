import SwiftUI

/// The Ledger Atlas mark (Assets/Brand/ledger-atlas-mark.svg) drawn in SwiftUI: a globe whose
/// parallels are ledger rules, one meridian, and a single coordinate dot, on the accent tile.
/// Drawing it keeps the welcome screen on brand even where the app icon is not bundled, such
/// as test runs, where `applicationIconImage` is the generic folder.
struct LedgerAtlasMark: View {
  var size: CGFloat = 72

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
        .fill(LedgerTheme.accent)
      Canvas { context, canvas in
        Self.draw(in: &context, side: min(canvas.width, canvas.height))
      }
      .frame(width: size * 0.62, height: size * 0.62)
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }

  /// The SVG's 64-unit drawing scaled to `side`.
  private static func draw(in context: inout GraphicsContext, side: CGFloat) {
    let unit = side / 64
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * unit, y: y * unit) }
    func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> Path {
      Path(ellipseIn: CGRect(x: (x - r) * unit, y: (y - r) * unit, width: 2 * r * unit, height: 2 * r * unit))
    }
    let ink = GraphicsContext.Shading.color(LedgerTheme.onAccent)

    // Globe, rules and meridian, with a clear halo around the coordinate dot.
    context.drawLayer { layer in
      layer.stroke(circle(32, 32, 27), with: ink, lineWidth: 4 * unit)
      layer.drawLayer { disc in
        disc.clip(to: circle(32, 32, 27))
        for y in [10.75, 20.75, 30.75, 40.75, 50.75] as [CGFloat] {
          disc.fill(Path(CGRect(x: 0, y: y * unit, width: 64 * unit, height: 2.5 * unit)), with: ink)
        }
        var meridian = Path()
        meridian.move(to: point(32, 5))
        meridian.addQuadCurve(to: point(32, 59), control: point(59, 32))
        disc.stroke(meridian, with: ink, lineWidth: 3.5 * unit)
      }
      layer.blendMode = .destinationOut
      layer.fill(circle(44.5, 22, 9), with: ink)
    }
    context.fill(circle(44.5, 22, 5.5), with: ink)
  }
}
