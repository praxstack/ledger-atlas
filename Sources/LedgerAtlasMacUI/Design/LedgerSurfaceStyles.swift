import SwiftUI

/// Surfaces and controls of the Ledger Atlas look.
///
/// Glass belongs to navigation only (the sidebar and toolbar float above the content, as in
/// macOS 26). Cards, tables and the inspector are solid so figures stay sharp. On macOS 26 the
/// floating pieces use Liquid Glass; on macOS 15 they use the system materials. Both turn
/// solid by themselves when Reduce Transparency is on.
extension View {
  /// A raised card on the canvas: solid fill, hairline edge, 14 pt corners.
  public func ledgerCard(padding: CGFloat = LedgerTheme.Space.xl) -> some View {
    modifier(LedgerCardModifier(padding: padding))
  }

  /// A grouped box for key-value rows (inspector, sheets).
  public func ledgerGroupBox() -> some View {
    modifier(LedgerHairlineBox(radius: LedgerTheme.Radius.group, shadow: false))
  }

  /// A floating glass capsule for toolbar-like control groups drawn inside content.
  public func ledgerGlassCapsule() -> some View {
    modifier(LedgerGlassModifier(shape: .capsule))
  }

  /// A floating glass panel (rounded rectangle).
  public func ledgerGlassPanel(cornerRadius: CGFloat = LedgerTheme.Radius.panel) -> some View {
    modifier(LedgerGlassModifier(shape: .rounded(cornerRadius)))
  }

  /// The solid window canvas behind content.
  public func ledgerCanvas() -> some View {
    background(LedgerTheme.canvas)
  }
}

struct LedgerCardModifier: ViewModifier {
  let padding: CGFloat

  func body(content: Content) -> some View {
    content
      .padding(padding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .modifier(LedgerHairlineBox(radius: LedgerTheme.Radius.card, shadow: true))
  }
}

/// A solid card fill with a one-pixel hairline edge (0.5 pt drew nothing on 1x screens) and,
/// for raised cards, a soft light-mode shadow.
struct LedgerHairlineBox: ViewModifier {
  let radius: CGFloat
  let shadow: Bool
  @Environment(\.displayScale) private var displayScale

  func body(content: Content) -> some View {
    content
      .background {
        RoundedRectangle(cornerRadius: radius)
          .fill(LedgerTheme.card)
          .shadow(color: shadow ? LedgerTheme.cardShadow : .clear, radius: 3, y: 1)
      }
      .overlay(
        RoundedRectangle(cornerRadius: radius)
          .strokeBorder(LedgerTheme.hairline, lineWidth: 1 / max(displayScale, 1))
      )
  }
}

enum LedgerGlassShape {
  case capsule
  case rounded(CGFloat)
}

struct LedgerGlassModifier: ViewModifier {
  let shape: LedgerGlassShape
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  func body(content: Content) -> some View {
    switch shape {
    case .capsule: glass(content, in: Capsule())
    case .rounded(let radius): glass(content, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
  }

  @ViewBuilder
  private func glass<S: Shape>(_ content: Content, in shape: S) -> some View {
    if reduceTransparency {
      content.background(LedgerTheme.card, in: shape).overlay(shape.stroke(LedgerTheme.hairline, lineWidth: 0.5))
    } else {
      // Swift 6.2 ships with the macOS 26 SDK, the first with `glassEffect`; older
      // toolchains build the material fallback only.
      #if compiler(>=6.2)
        if #available(macOS 26, *) {
          content.glassEffect(.regular, in: shape)
        } else {
          content.background(.regularMaterial, in: shape).overlay(shape.stroke(LedgerTheme.hairline, lineWidth: 0.5))
        }
      #else
        content.background(.regularMaterial, in: shape).overlay(shape.stroke(LedgerTheme.hairline, lineWidth: 0.5))
      #endif
    }
  }
}

/// The one primary action on a surface: accent fill, white label.
public struct LedgerPrimaryButtonStyle: ButtonStyle {
  public var large: Bool

  public init(large: Bool = false) { self.large = large }

  public func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(large ? Font.system(.body, weight: .semibold) : Font.system(.callout, weight: .semibold))
      .foregroundStyle(LedgerTheme.onAccent)
      .padding(.horizontal, large ? 16 : 11)
      .frame(height: large ? 34 : 26)
      .background(
        configuration.isPressed ? LedgerTheme.accentPressed : LedgerTheme.accent,
        in: .rect(cornerRadius: large ? 9 : LedgerTheme.Radius.control)
      )
      .contentShape(.rect)
  }
}

/// A quiet secondary action: field fill, ink label.
public struct LedgerSecondaryButtonStyle: ButtonStyle {
  public init() {}

  public func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(.callout, weight: .medium))
      .foregroundStyle(LedgerTheme.ink)
      .padding(.horizontal, 11)
      .frame(height: 26)
      .background(
        configuration.isPressed ? LedgerTheme.fieldFillPressed : LedgerTheme.fieldFill,
        in: .rect(cornerRadius: LedgerTheme.Radius.control)
      )
      .contentShape(.rect)
  }
}

/// A destructive action (Reset): a quiet button with its label in the negative colour.
/// `role: .destructive` alone doesn't colour a bordered button on macOS.
public struct LedgerDestructiveButtonStyle: ButtonStyle {
  public init() {}

  public func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(.callout, weight: .medium))
      .foregroundStyle(LedgerTheme.negative)
      .padding(.horizontal, 11)
      .frame(height: 26)
      .background(
        configuration.isPressed ? LedgerTheme.fieldFillPressed : LedgerTheme.fieldFill,
        in: .rect(cornerRadius: LedgerTheme.Radius.control)
      )
      .modifier(LedgerFocusRing(radius: LedgerTheme.Radius.control))
      .contentShape(.rect)
  }
}

/// A visible keyboard-focus ring for custom button styles, which lose the system one.
struct LedgerFocusRing: ViewModifier {
  var radius: CGFloat
  @Environment(\.isFocused) private var isFocused

  func body(content: Content) -> some View {
    content.overlay {
      if isFocused {
        RoundedRectangle(cornerRadius: radius)
          .strokeBorder(LedgerTheme.accent, lineWidth: 2)
          .padding(-3)
          .allowsHitTesting(false)
      }
    }
  }
}

/// An inline text link in the accent colour. The system `.link` style is always system blue,
/// a second accent next to the teal.
public struct LedgerLinkButtonStyle: ButtonStyle {
  public init() {}

  public func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(configuration.isPressed ? LedgerTheme.accentPressed : LedgerTheme.accent)
      // An underline so the link does not rely on colour alone inside body text.
      .underline()
      .modifier(LedgerFocusRing(radius: 3))
      .contentShape(.rect)
  }
}

/// A filter chip ("October 2026", "All accounts").
public struct LedgerChip: View {
  let title: String
  let systemImage: String?

  public init(_ title: String, systemImage: String? = nil) {
    self.title = title
    self.systemImage = systemImage
  }

  public var body: some View {
    HStack(spacing: 6) {
      if let systemImage {
        Image(systemName: systemImage).font(.system(.caption, weight: .semibold)).foregroundStyle(LedgerTheme.inkTertiary)
      }
      Text(title).font(.system(.callout, weight: .medium))
    }
    .foregroundStyle(LedgerTheme.ink)
    .padding(.horizontal, 10)
    .frame(height: 26)
    .background(LedgerTheme.fieldFill, in: .rect(cornerRadius: LedgerTheme.Radius.control))
  }
}

/// A card header: title on the left, a quiet detail or action on the right.
public struct LedgerCardHeader<Trailing: View>: View {
  let title: String
  let trailing: Trailing

  public init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
    self.title = title
    self.trailing = trailing()
  }

  public var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Text(title).font(LedgerTheme.Typeface.cardTitle).foregroundStyle(LedgerTheme.ink)
        .accessibilityAddTraits(.isHeader)
      Spacer(minLength: 8)
      trailing.font(LedgerTheme.Typeface.secondary).foregroundStyle(LedgerTheme.inkTertiary)
    }
  }
}

extension LedgerCardHeader where Trailing == EmptyView {
  public init(_ title: String) { self.init(title) { EmptyView() } }
}

/// A small square colour key for categories and accounts.
public struct LedgerColorKey: View {
  let color: Color
  public init(_ color: Color) { self.color = color }
  public var body: some View {
    RoundedRectangle(cornerRadius: 2.5).fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
  }
}

/// A rounded tile with a symbol or initials, used for payees and categories in rows.
public struct LedgerIconTile: View {
  public enum Content {
    case symbol(String)
    case initials(String)
  }

  let content: Content
  let swatch: LedgerTheme.Swatch
  let size: CGFloat

  public init(_ content: Content, swatch: LedgerTheme.Swatch, size: CGFloat = LedgerTheme.Metrics.iconTile) {
    self.content = content
    self.swatch = swatch
    self.size = size
  }

  public var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: size * 0.29, style: .continuous).fill(swatch.soft)
      switch content {
      case .symbol(let name):
        Image(systemName: name).font(.system(.callout, weight: .semibold)).foregroundStyle(swatch.color)
      case .initials(let text):
        Text(text).font(.system(.caption, weight: .bold)).foregroundStyle(swatch.color)
      }
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}

/// A thin progress track (budgets, category share). Over 100% turns red and marks the limit.
public struct LedgerProgressTrack: View {
  let fraction: Double
  let tint: Color
  let height: CGFloat

  public init(fraction: Double, tint: Color = LedgerTheme.ink, height: CGFloat = 6) {
    self.fraction = fraction
    self.tint = tint
    self.height = height
  }

  public var body: some View {
    GeometryReader { proxy in
      let over = fraction > 1
      ZStack(alignment: .leading) {
        Capsule().fill(LedgerTheme.track)
        Capsule().fill(over ? LedgerTheme.negative : tint)
          .frame(width: proxy.size.width * min(max(fraction, 0), 1))
        if over {
          Rectangle().fill(LedgerTheme.card).frame(width: 1.5)
            .offset(x: proxy.size.width / fraction)
        }
      }
    }
    .frame(height: height)
    .accessibilityHidden(true)
  }
}
