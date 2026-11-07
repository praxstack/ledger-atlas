import SwiftUI

/// The figures strip at the top of a screen (Money in / Spending / Net, Total balance …):
/// captions above figures, aligned on the figures' baseline, the most important one last.
struct LedgerSummaryStrip<Content: View>: View {
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

/// One captioned figure in a `LedgerSummaryStrip`. Unlike `LedgerFigure` it takes the
/// `MoneyText` itself, so each figure can choose its own size, sign and tone.
struct LedgerSummaryFigure: View {
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
