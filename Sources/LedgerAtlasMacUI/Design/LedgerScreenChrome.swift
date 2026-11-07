import LedgerCore
import SwiftUI

/// Shared pieces of screen chrome: empty states, status lines, action bars, plain rows and
/// small figures. Every screen outside the Transactions table is built from these plus the
/// cards in `LedgerSurfaceStyles`, so they all share one voice.

/// A centred empty state: an icon tile, a title, a short explanation and the actions that
/// get the person out of it.
struct LedgerEmptyState<Actions: View>: View {
  let title: String
  let systemImage: String
  let message: String
  let actions: Actions

  init(_ title: String, systemImage: String, message: String, @ViewBuilder actions: () -> Actions) {
    self.title = title
    self.systemImage = systemImage
    self.message = message
    self.actions = actions()
  }

  var body: some View {
    VStack(spacing: LedgerTheme.Space.m) {
      ZStack {
        RoundedRectangle(cornerRadius: LedgerTheme.Radius.tile, style: .continuous).fill(LedgerTheme.fieldFill)
        Image(systemName: systemImage)
          .font(LedgerTheme.Typeface.figure)
          .foregroundStyle(LedgerTheme.inkSecondary)
      }
      .frame(width: 44, height: 44)
      .accessibilityHidden(true)
      Text(title)
        .font(LedgerTheme.Typeface.screenTitle)
        .foregroundStyle(LedgerTheme.ink)
        .multilineTextAlignment(.center)
        .accessibilityAddTraits(.isHeader)
      // No fixedSize here: these screens don't scroll, and a fixed-height paragraph is measured
      // at the window's narrowest width, which made the window taller than the display (the
      // Installments empty state pushed Begin editing off screen).
      Text(message)
        .font(LedgerTheme.Typeface.secondary)
        .foregroundStyle(LedgerTheme.inkSecondary)
        .multilineTextAlignment(.center)
        .lineLimit(4)
      HStack(spacing: LedgerTheme.Space.s) { actions }
        .padding(.top, LedgerTheme.Space.xs)
    }
    .frame(maxWidth: 420)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(LedgerTheme.Space.xxxl)
  }
}

extension LedgerEmptyState where Actions == EmptyView {
  init(_ title: String, systemImage: String, message: String) {
    self.init(title, systemImage: systemImage, message: message) { EmptyView() }
  }
}

/// One line of status under a form or list: a failure in the alert colour with a warning
/// symbol, otherwise a quiet status sentence. Nothing is drawn when both are nil.
struct LedgerStatusLine: View {
  let failure: String?
  let status: String?

  init(failure: String? = nil, status: String? = nil) {
    self.failure = failure
    self.status = status
  }

  var body: some View {
    if let failure {
      Label(failure, systemImage: "exclamationmark.triangle")
        .font(LedgerTheme.Typeface.secondary)
        .foregroundStyle(LedgerTheme.negative)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel(failure)
    } else if let status {
      Text(status)
        .font(LedgerTheme.Typeface.secondary)
        .foregroundStyle(LedgerTheme.inkSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel(status)
    }
  }
}

/// A bar of actions on the recessed canvas, separated from the content above by a hairline.
/// The same bar the Transactions table shows while editing.
struct LedgerActionBar<Content: View>: View {
  let content: Content

  init(@ViewBuilder content: () -> Content) { self.content = content() }

  var body: some View {
    HStack(spacing: LedgerTheme.Space.s) { content }
      .padding(.horizontal, LedgerTheme.Space.l)
      .padding(.vertical, LedgerTheme.Space.s)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(LedgerTheme.recessed)
      .overlay(alignment: .top) { Rectangle().fill(LedgerTheme.hairline).frame(height: 0.5) }
  }
}

/// A plain row inside a card: an optional leading tile, a title with a quiet detail under it,
/// and trailing content (a figure, a badge, a chevron).
struct LedgerRow<Leading: View, Trailing: View>: View {
  let title: String
  let detail: String?
  let leading: Leading
  let trailing: Trailing

  init(
    _ title: String, detail: String? = nil,
    @ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing
  ) {
    self.title = title
    self.detail = detail
    self.leading = leading()
    self.trailing = trailing()
  }

  var body: some View {
    HStack(spacing: LedgerTheme.Space.m) {
      leading
      VStack(alignment: .leading, spacing: LedgerTheme.Space.xxs) {
        Text(title)
          .font(LedgerTheme.Typeface.bodyEmphasis)
          .foregroundStyle(LedgerTheme.ink)
          .lineLimit(1)
        if let detail, !detail.isEmpty {
          Text(detail)
            .font(LedgerTheme.Typeface.caption)
            .foregroundStyle(LedgerTheme.inkTertiary)
            .lineLimit(1)
        }
      }
      Spacer(minLength: LedgerTheme.Space.s)
      trailing
    }
    .frame(minHeight: LedgerTheme.Metrics.tableRow)
    .contentShape(.rect)
  }
}

extension LedgerRow where Leading == EmptyView {
  init(_ title: String, detail: String? = nil, @ViewBuilder trailing: () -> Trailing) {
    self.init(title, detail: detail, leading: { EmptyView() }, trailing: trailing)
  }
}

extension LedgerRow where Leading == EmptyView, Trailing == EmptyView {
  init(_ title: String, detail: String? = nil) {
    self.init(title, detail: detail, leading: { EmptyView() }, trailing: { EmptyView() })
  }
}

/// A hairline between rows in a card, inset like the row text.
struct LedgerRowDivider: View {
  var body: some View {
    Rectangle().fill(LedgerTheme.hairlineSoft).frame(height: 0.5).accessibilityHidden(true)
  }
}

/// A small capsule badge ("Monthly", "3 of 12", "Paused").
struct LedgerBadge: View {
  let text: String
  let systemImage: String?
  let tint: Color

  init(_ text: String, systemImage: String? = nil, tint: Color = LedgerTheme.inkSecondary) {
    self.text = text
    self.systemImage = systemImage
    self.tint = tint
  }

  var body: some View {
    HStack(spacing: LedgerTheme.Space.xs) {
      if let systemImage {
        Image(systemName: systemImage).font(LedgerTheme.Typeface.badgeSymbol)
      }
      Text(text).font(LedgerTheme.Typeface.captionEmphasis)
    }
    .foregroundStyle(tint)
    .padding(.horizontal, LedgerTheme.Space.s)
    .frame(height: 20)
    .background(LedgerTheme.fieldFill, in: .capsule)
  }
}

/// A labelled figure for a strip of key numbers: a quiet caption over the amount.
struct LedgerFigure: View {
  let title: String
  let amount: CurrencyAmount
  let size: MoneyText.Size
  let sign: LedgerDisplayFormatter.SignStyle
  let negativeIsAlert: Bool

  init(
    _ title: String, amount: CurrencyAmount, size: MoneyText.Size = .figure,
    sign: LedgerDisplayFormatter.SignStyle = .negativeOnly, negativeIsAlert: Bool = false
  ) {
    self.title = title
    self.amount = amount
    self.size = size
    self.sign = sign
    self.negativeIsAlert = negativeIsAlert
  }

  var body: some View {
    VStack(alignment: .leading, spacing: LedgerTheme.Space.xxs) {
      Text(title)
        .font(LedgerTheme.Typeface.caption)
        .foregroundStyle(LedgerTheme.inkTertiary)
      MoneyText(amount, size: size, sign: sign, negativeIsAlert: negativeIsAlert)
    }
    .accessibilityElement(children: .combine)
  }
}

/// A key-value line inside a grouped box (inspector style): label left, value right.
struct LedgerKeyValue: View {
  let label: String
  let value: String

  init(_ label: String, _ value: String) {
    self.label = label
    self.value = value
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: LedgerTheme.Space.l) {
      Text(label).font(LedgerTheme.Typeface.secondary).foregroundStyle(LedgerTheme.inkSecondary)
      Spacer(minLength: LedgerTheme.Space.m)
      Text(value)
        .font(LedgerTheme.Typeface.secondary)
        .foregroundStyle(LedgerTheme.ink)
        .multilineTextAlignment(.trailing)
    }
    .padding(.vertical, LedgerTheme.Space.s)
    .accessibilityElement(children: .combine)
  }
}

/// The scrolling column of cards most screens are made of. It is a plain `List` under the
/// skin, so each card is a row VoiceOver can step through and the keyboard can reach.
struct LedgerCardColumn<Content: View>: View {
  let maxWidth: CGFloat
  let content: Content

  init(maxWidth: CGFloat = 760, @ViewBuilder content: () -> Content) {
    self.maxWidth = maxWidth
    self.content = content()
  }

  var body: some View {
    List {
      Group { content }
        .frame(maxWidth: maxWidth, alignment: .leading)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .listRowInsets(
          EdgeInsets(
            top: LedgerTheme.Space.s, leading: LedgerTheme.Space.xxl, bottom: LedgerTheme.Space.s,
            trailing: LedgerTheme.Space.xxl))
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .contentMargins(.vertical, LedgerTheme.Space.l, for: .scrollContent)
    .ledgerCanvas()
  }
}

/// A list of title-and-detail rows (the data-backed surfaces and the read-only fallbacks).
struct LedgerSurfaceRowList: View {
  let rows: [LedgerJourney.SurfaceRow]

  var body: some View {
    List(rows) { row in
      LedgerRow(row.title, detail: row.detail)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.title), \(row.detail)")
    }
    .scrollContentBackground(.hidden)
    .ledgerCanvas()
  }
}

/// The empty, loading and unavailable states of a screen that needs an open ledger. The
/// titles and the "Open Ledger…" button are what the empty-state checks look for.
struct LedgerSessionEmptyState: View {
  let state: LedgerSession.State
  let title: String
  let systemImage: String
  let message: String
  let failure: String?
  let open: () -> Void

  var body: some View {
    switch state {
    case .loaded:
      LedgerEmptyState(title, systemImage: systemImage, message: message)
    case .loading:
      OpeningLedgerView().frame(maxWidth: .infinity, maxHeight: .infinity)
    case .unavailable:
      LedgerEmptyState(
        "Ledger unavailable", systemImage: "exclamationmark.triangle",
        message: [LedgerLifecycleGuidance.unavailable.text(retrying: nil), failure].compactMap { $0 }
          .joined(separator: " ")
      ) {
        Button("Open Ledger…", action: open).buttonStyle(LedgerPrimaryButtonStyle())
      }
    case .noLedger:
      LedgerEmptyState(
        "Open a ledger", systemImage: "folder",
        message: [LedgerLifecycleGuidance.noLedger.text(retrying: nil), failure].compactMap { $0 }
          .joined(separator: " ")
      ) {
        Button("Open Ledger…", action: open).buttonStyle(LedgerPrimaryButtonStyle())
      }
    }
  }
}

extension View {
  /// Row actions appear only while the ledger is being edited. Shown but disabled, the
  /// "Actions" menus read as broken, and in dark mode they nearly vanished.
  @ViewBuilder func shownWhileEditing(_ isEditing: Bool) -> some View {
    if isEditing { self }
  }
}

/// The label of a row's actions menu: a quiet ellipsis instead of a bordered "Actions ⌄"
/// button on every row. The menu's accessibility label names the row ("Actions for Cash").
struct LedgerRowActionsLabel: View {
  var body: some View {
    Image(systemName: "ellipsis.circle")
      .font(LedgerTheme.Typeface.body)
      .foregroundStyle(LedgerTheme.inkSecondary)
      .accessibilityHidden(true)
  }
}

extension View {
  /// Borderless with no disclosure arrow, so only the ellipsis shows.
  func ledgerRowActionsMenu() -> some View {
    menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
  }
}
