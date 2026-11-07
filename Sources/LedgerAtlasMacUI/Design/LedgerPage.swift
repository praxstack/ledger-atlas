import SwiftUI

/// The page every screen outside the Transactions table sits on: the canvas, one gutter, a
/// column of cards that stops growing at `pageMaxWidth`, and the same vertical rhythm. The
/// toolbar carries the screen's title, so the page doesn't repeat it as a large heading.
///
///     LedgerPage {
///       LedgerPageSummary { … figures … }
///       LedgerPageSection("Accounts") { … rows … }
///     }
struct LedgerPage<Content: View>: View {
  let content: Content

  init(@ViewBuilder content: () -> Content) { self.content = content() }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: LedgerTheme.Space.xl) { content }
        .frame(maxWidth: LedgerTheme.Metrics.pageMaxWidth, alignment: .leading)
        .padding(.horizontal, LedgerTheme.Metrics.pageGutter)
        .padding(.vertical, LedgerTheme.Space.xxl)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .ledgerCanvas()
  }
}

/// A titled card on a page: the shared card header, then the content in one card. Rows inside
/// it are separated with `LedgerPageDivider`.
struct LedgerPageSection<Trailing: View, Content: View>: View {
  let title: String
  let trailing: Trailing
  let content: Content

  init(
    _ title: String, @ViewBuilder trailing: () -> Trailing,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.trailing = trailing()
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: LedgerTheme.Space.s) {
      LedgerCardHeader(title) { trailing }
      VStack(alignment: .leading, spacing: 0) { content }
        .ledgerCard()
    }
    .accessibilityElement(children: .contain)
  }
}

extension LedgerPageSection where Trailing == EmptyView {
  init(_ title: String, @ViewBuilder content: () -> Content) {
    self.init(title, trailing: { EmptyView() }, content: content)
  }
}

/// The hairline between rows in a page section, inset to the text so it lines up with the
/// titles rather than the icon tiles.
struct LedgerPageDivider: View {
  var inset: CGFloat = LedgerTheme.Metrics.iconTile + LedgerTheme.Space.m

  var body: some View {
    Rectangle()
      .fill(LedgerTheme.hairline)
      .frame(height: 1)
      .padding(.leading, inset)
      .accessibilityHidden(true)
  }
}

/// The figures strip at the top of a page (Money in / Spending / Net, Total balance …):
/// captions above figures, aligned on the figures' baseline, the most important one last.
struct LedgerPageSummary<Content: View>: View {
  let content: Content

  init(@ViewBuilder content: () -> Content) { self.content = content() }

  var body: some View {
    HStack(alignment: .lastTextBaseline, spacing: LedgerTheme.Space.xxl) {
      content
      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .combine)
  }
}

/// One captioned figure in a `LedgerPageSummary`.
struct LedgerPageFigure: View {
  let label: String
  let figure: MoneyText

  init(_ label: String, _ figure: MoneyText) {
    self.label = label
    self.figure = figure
  }

  var body: some View {
    VStack(alignment: .leading, spacing: LedgerTheme.Space.xxs) {
      Text(label)
        .font(LedgerTheme.Typeface.caption)
        .foregroundStyle(LedgerTheme.inkSecondary)
      figure
    }
  }
}

extension View {
  /// Caps a paragraph of explanation at a readable line length.
  func ledgerReadableWidth() -> some View {
    frame(maxWidth: LedgerTheme.Metrics.readableWidth, alignment: .leading)
  }
}
