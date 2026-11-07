# Ledger Atlas Design System

Status: **accepted 2026-11-03** (Prax approved the "Pro look", mock at https://claude.ai/artifact/V1TbBn828ASQ1BBokD91Qc). This file governs every visual and interaction decision in the Mac app. Code tokens live in `Sources/LedgerAtlasMacUI/Design/`; when this file and the code disagree, fix one of them in the same pull request.

## 1. Product intent

Ledger Atlas is a private, local-first money manager for people who want the speed and exactness of a Mac app and keep their whole Money Manager history. It should look like a shipping, award-level pro app: calm, precise and dense, with numbers as the hero.

Product promises the interface makes visible:

- Every amount is exact, aligned, and carries its currency.
- Every import is reviewed before it writes. Imported rows say where they came from.
- Every destructive or history-changing action states its consequence.
- Source files stay read-only. Nothing leaves the Mac.

## 2. The look in five rules

1. **Glass on navigation only.** The sidebar floats as a glass panel and toolbar controls sit in glass capsules (macOS 26 Liquid Glass; system materials on macOS 15). Content (cards, tables, the inspector) is solid, so figures stay crisp. Never stack glass on glass.
2. **One accent, used sparingly.** Deep teal marks selection, focus and the single primary action on a surface. Neutral greys do everything else.
3. **Colour means something.** Green = money in. Red = over budget, a negative balance, an error or a destructive action. Spending is plain ink. Category colours appear only as 8 pt keys and thin bars.
4. **Numbers set like a bank's.** Tabular figures, tight tracking on large figures, the currency symbol and fraction at reduced strength so whole units read first, a true minus sign (−, U+2212), rupees always in Indian grouping (₹4,83,676.30).
5. **Density with air.** 40 pt table rows, hairline separators, a 4 pt grid, shared left edges from sidebar to inspector.

## 3. Tokens

Source: `LedgerTheme.swift`. Every colour resolves for light, dark, and both Increase Contrast appearances. Every text colour reaches 4.5:1 on the canvas and cards, and 7:1 with Increase Contrast (`themeTextColoursMeetContrastMinimums`).

### 3.1 Colour

| Token | Light | Dark | Use |
|---|---|---|---|
| `canvas` | `#F5F5F4` | `#1C1C1E` | Window content background behind every screen |
| `recessed` | `#F0F0EE` | `#161618` | Inspector, drop zones, day headers (below the canvas in both looks) |
| `card` | `#FFFFFF` | `#28282B` | Cards on the canvas (above it in both looks) |
| `ink` | `#1D1D1F` | `#F5F5F7` | Primary text, spending amounts |
| `inkSecondary` | `#515154` | `#C7C7CC` | Secondary text |
| `inkTertiary` | `#69696D` | `#8E8E93` | Labels, captions, axis text |
| `hairline` | black 8% | white 9% | Separators (22% / 26% with Increase Contrast) |
| `inkQuiet`, `positiveQuiet`, `negativeQuiet` | their colour, faded only as far as 4.5:1 allows | same | The currency symbol and paise of a figure |
| `fieldFill` | black 6% | white 10% | Fields, chips, segmented items |
| `accent` | `#09747D` | `#4FC3CE` | Selection, focus, primary action |
| `accentSoft` | accent 11% | accent 16% | Selected rows, provenance note |
| `positive` | `#1B774A` | `#4CC985` | Money in |
| `negative` | `#BA3E2B` | `#FF7A66` | Over budget, negative balance, errors |
| `warning` | `#975B00` | `#F0A83C` | Needs review |

Category palette (muted, equal perceived lightness), light / dark: blue `#5B7FB8`/`#7D9FD6`, copper `#C27A46`/`#DF9764`, sage `#6E9E72`/`#8CBF90`, ochre `#C2A245`/`#DCBD60`, mauve `#A7709D`/`#C690BB`, teal `#5E9EA3`/`#7DBDC2`, rose `#B5666A`/`#D68589`, slate `#8B8F97`/`#A3A7AE`. A name always maps to the same colour (`LedgerTheme.paletteColor(for:)`).

### 3.2 Type

SF Pro only (system font); no bundled faces. Every style is a **system text style**, never a fixed point size, so text follows the Mac's text size and display zoom (enforced by `everyFontIsASystemTextStyle`). Money uses `MoneyText`, which adds tabular figures and tightens large figures.

| Style | Text style | Use |
|---|---|---|
| `hero` | Large Title, semibold | The one hero figure on a screen (net worth) |
| `display` | Large Title, bold | Welcome and empty-state titles |
| `figureLarge` | Title, semibold | Inspector amount |
| `figure` | Title 2, semibold | Key figures in cards |
| `screenTitle` | Title 3, bold | Screen titles |
| `cardTitle` | Headline | Card and section titles |
| `body` / `bodyEmphasis` | Body / Body medium | Rows, labels, row amounts |
| `secondary` | Callout | Secondary lines, sidebar balances |
| `caption` | Subheadline | Captions, axis labels |

### 3.3 Space, shape, size

- Spacing: 2, 4, 8, 12, 16, 20, 24, 32.
- Radius: control 7, row 8, group 10, card 14, panel (sidebar, sheets) 16. Corners are concentric with the window.
- Rows: table 40, compact 28, sidebar 27. Icon tile 28. Inspector width 320. Sidebar 240–300.

## 4. Components

All in `Sources/LedgerAtlasMacUI/Design/`.

- **MoneyText**: sizes `hero`, `large`, `figure`, `row`, `small`, `caption`; sign styles `negativeOnly` (balances), `always` (transactions, cash flow), `never` (limits). Tone `automatic` colours only money in, and red for negative balances when `negativeIsAlert` is set. VoiceOver reads the plain formatted amount.
- **ledgerCard()**: solid card, hairline edge, 14 pt corners, 20 pt padding.
- **ledgerGroupBox()**: key-value box inside cards, sheets and the inspector.
- **ledgerGlassCapsule() / ledgerGlassPanel()**: floating glass; solid card fill under Reduce Transparency.
- **LedgerPrimaryButtonStyle**: one per surface. **LedgerSecondaryButtonStyle** for the rest. Destructive actions use the system destructive role.
- **LedgerChip**: filter tokens above tables.
- **LedgerCardHeader**: title left (header trait), quiet detail or link right.
- **LedgerColorKey**: 8 pt rounded square for categories and accounts.
- **LedgerIconTile**: 28 pt tile with an SF Symbol or payee initials on a 16% tint.
- **LedgerProgressTrack**: budgets and shares; over 100% turns red and marks the limit.

## 5. Layout

- **Window**: `NavigationSplitView`. Sidebar is a floating glass panel (system sidebar style on macOS 26). Minimum window 1000 × 640; the inspector collapses before the table truncates.
- **Sidebar**: Money (Transactions, Accounts, Budgets, Insights, Recurring), then Accounts with live balances in the person's group order (closed and hidden accounts left out; a negative balance on an asset account is red), then Organise (Categories, Tags & Memos, Transfers, Installments, Receipts, Search), then Ledger (Import Review, Backup & Restore, Local Access, Get Started, Settings). Until a ledger is open, an import card is pinned at the bottom (solid, since the sidebar is already glass); after that, Import lives in the toolbar and the File menu (⇧⌘I). Every screen stays in the sidebar so the keyboard reaches all of them.
- **Toolbar**: screen title and subtitle on the left; on the right, glass capsule groups: period (‹ October 2026 ›), scope (Month / Quarter / Year), view controls, then Import and **+ New** (primary).
- **Overview**: left column net-worth card (hero figure, change badge, 12-month line chart, In / Out / Saved strip) and Recent transactions; right column (330 pt) Cash flow, Spending by category, Budgets.
- **Transactions**: filter chips, In / Out / Net summary line, a table grouped by day with day totals, and a 320 pt inspector showing amount, payee, category, account, tags, note, budget, receipt and provenance ("Imported, unchanged" with backup date and source row).
- **First launch**: one centred column: app mark, "Bring over your Money Manager history", a drop zone with **Choose backup…** (⇧⌘I), the three steps (Choose, Review, Approve), then quiet links (Start an empty ledger, Open a ledger…, Try sample data) and the privacy line.

## 6. Charts

Swift Charts. One question per chart, and every chart has an accessible table or summary.

- Net worth: 1.75 pt accent line, accent area fading from 20% to 0, hairline grid, right-side axis in lakh (₹4.5L), month labels below, a ringed point on the latest value.
- Cash flow: paired rounded bars per month, money in green, money out ink at 80%; past months at 35% / 22%.
- Spending: horizontal 4 pt bars in category colours, share as a percentage.
- No 3D, gauges, donuts with labels inside, decorative gradients or animated totals.

## 7. Accessibility

- **Colour guard**: only `LedgerTheme.swift` may define colours, and each token there carries its own Increase Contrast value (`themeColoursHaveIncreaseContrastValues`). Elsewhere, no hand-mixed colours and no `.opacity(` (`everyColourFollowsIncreaseContrast`); use a token such as `inkQuiet` or a swatch's `soft` instead.
- **Reduce Transparency**: every glass surface turns solid (`card` fill + hairline). System materials do this themselves; custom glass checks `accessibilityReduceTransparency`.
- **Increase Contrast**: dynamic colours switch to their high-contrast values; hairlines become 22–26%.
- **Reduce Motion**: crossfade or no transition (`MotionPolicy`).
- Colour is never the only signal: amounts carry + or −; over-budget rows say "over".
- Minimum target 28 × 28 pt. Every icon-only button has a label, help text and a keyboard path.
- VoiceOver: rows read payee, category, account, amount; charts expose a summary.

## 8. Keyboard

`⇧⌘N` new ledger · `⌘O` open ledger · `⇧⌘I` import Money Manager backup · `⌘F` search · `⌥⌘F` filters · `⌥⌘I` inspector · `⌘Z` / `⇧⌘Z` undo, redo · Return edits the selected row · Space previews · Delete asks first. Every shortcut also exists in a menu.

## 9. Motion

80–120 ms for control feedback, 160–220 ms for inspector and selection. Native springs only where they explain spatial change. No perpetual animation, shimmer, parallax or animated money.

## 10. Content style

- Direct verbs: Import, Review, Approve, Back Up, Restore.
- Say the consequence: "Your backup file is only read, never changed."
- Plain words over system words: "money in", "spending", "saved", not "inflow", "debit", "delta".
- No hype words (seamless, effortless, smart, AI-powered). No blame ("This backup isn't supported yet", not "Invalid backup").

## 11. States

Every surface defines: no ledger (import first), empty ledger, no results (keep filters, offer reset), loading (name the phase), unavailable or damaged (disable edits, explain recovery), permission denied (re-select the file).

## 12. Never

- Glass behind tables or figures, or glass on glass.
- More than one accent, or accent used for decoration.
- Red for ordinary spending by default.
- Purple/blue neon gradients, blobs, glowing buttons, emoji as icons.
- A dashboard of identical statistic tiles.
- Hyphen-minus in amounts, Western grouping for rupees, unlabelled currency.
- A Money Manager clone or its branding.

## 13. Decision log

| Date | Decision | Rationale |
|---|---|---|
| 2026-08-20 | Quiet Financial Instrument, system typography | Native precision over fintech spectacle. |
| 2026-11-03 | Three concept directions (Double Rule, Strata, Contour) | Rejected by Prax as gimmicky; metaphors read as childish. |
| 2026-11-03 | Adopt the "Pro look" | Approved by Prax. Follows Apple's Liquid Glass guidance (glass on navigation), Linear's colour restraint and the figure treatment of Mercury and Stripe. |
| 2026-11-03 | Accent moves from mineral green to deep teal | Green is reserved for money in; the accent must not read as income. |
| 2026-11-03 | Spending in ink by default (`AmountColors.incomeGreen`) | Red only signals a problem. The old red-for-spending styles stay available in Settings. |
| 2026-11-03 | Rupees always use Indian grouping | ₹4,83,676.30 is how rupee figures are read, whatever the display locale. |
| 2026-11-03 | Text colours tuned to 4.5:1 (7:1 with Increase Contrast) | Review of #161: the quiet symbol and paise and the light-mode green fell below AA. |
| 2026-11-03 | Sidebar grouped into Money, Accounts, Organise and Ledger | The sixteen equal destinations read as a development inventory; grouping keeps every screen one click and one arrow key away. |
| 2026-11-03 | The backup's time zone starts at this Mac's zone | Import used to fail with "Choose the backup's source time zone" after the file was picked. The zone is shown on the welcome screen and in the review before anything is written. |
