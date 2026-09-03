# Ledger Atlas Design System

Status: proposed design contract for the native macOS product. This file governs visual and interaction decisions; it does not certify import compatibility or product readiness.

## 1. Product intent

Ledger Atlas is a private, local-first personal-finance workbench for people who want the speed and control of a Mac without surrendering the exact history of their existing Money Manager data.

The product must feel like a trusted financial instrument, not a fintech advertisement. Its memorable quality is calm command: a dense financial history becomes legible, editable, and safe without feeling clinical or intimidating.

The first client is a native macOS application. Vendor formats remain at the import perimeter. All screenshots, prompts, prototypes, and fixtures use synthetic data only.

### Product promises visible in the interface

- Every amount is exact, aligned, and paired with its currency.
- Every import is reviewed before it writes.
- Every unsupported item is mapped, preserved, deliberately excluded with a reason, or blocks the import.
- Every destructive or history-changing action explains its consequence and supports recovery where possible.
- Imported source files remain read-only.
- The interface never implies compatibility beyond a named, tested profile.

### Design quality bar

“Award-winning” is an aspiration, not a label. The measurable bar is:

1. A first-time user can import or open a ledger without reading documentation.
2. A daily user can create, correct, search, and reconcile transactions mostly from the keyboard.
3. A reviewer can understand import loss, preservation, timezone, and destination before approval.
4. Money, dates, provenance, warnings, and empty states remain unambiguous at every window size.
5. VoiceOver, Full Keyboard Access, Reduce Motion, increased contrast, and text scaling remain first-class.

## 2. Visual thesis

### Direction: Quiet Financial Instrument

Ledger Atlas combines the economy of a well-made ledger, the tactility of a drafting table, and the clarity of native Mac software. It is balanced rather than airy, structured rather than card-heavy, and warm enough to invite daily use.

- **Density:** 7/10, daily-app dense. Transactions and accounts should scan quickly without becoming a cockpit.
- **Variance:** 4/10. Strong hierarchy and occasional asymmetric inspector layouts; never decorative chaos.
- **Motion:** 2/10. Motion explains state changes and never animates continuously.
- **Decoration:** intentional and restrained. Fine rules, subtle material shifts, careful type, and excellent spacing do the work.
- **Personality:** exact, humane, private, durable, quietly confident.

### Safe choices

- Native macOS sidebar, toolbar, tables, sheets, inspectors, menus, and keyboard commands.
- Conventional debit/credit and income/expense semantic colors, always reinforced by signs and labels.
- Right-aligned tabular money, predictable selection, undo, and familiar search behavior.

### Deliberate risks

- Use a mineral green accent rather than category-standard fintech blue. It signals permanence and calm without resembling Money Manager.
- Treat provenance and reconciliation as visible product features, not developer metadata. Users can inspect why a row exists and what was preserved.
- Prefer flat, rule-separated financial surfaces over a dashboard made from identical rounded cards.

## 3. Native platform posture

The production app uses SwiftUI and AppKit conventions. Do not reproduce web patterns inside a Mac window.

- Use `NavigationSplitView` for primary hierarchy and a contextual inspector for detail.
- Use `Table` for transaction-dense views when column behavior matters; use `List` for short collections and navigation.
- Use standard menu commands, toolbar customization, sheets, confirmation dialogs, search fields, focus rings, context menus, drag and drop, and Quick Look where appropriate.
- Respect system light/dark appearance, accent preferences, reduced motion, increased contrast, keyboard navigation, and localization.
- Use system typography in production. SF Pro is the correct native Mac typeface. Do not bundle a decorative font merely to look “designed.”
- Stitch or web prototypes may use Geist and Geist Mono only as cross-platform approximations of SF Pro and SF Mono.

## 4. Token architecture

Use three layers: primitives define raw values; semantic tokens express meaning; component tokens specialize a control. Production Swift should centralize these values once rather than scatter literals through views.

### 4.1 Primitive tokens

#### Light appearance

| Token | Value | Purpose |
|---|---:|---|
| `canvas-0` | `#F4F3EF` | Warm application background |
| `surface-0` | `#FBFBF8` | Primary work surface |
| `surface-1` | `#ECEBE6` | Sidebar, recessed controls, selected-neutral state |
| `ink-950` | `#1B1D1C` | Primary text; never pure black |
| `ink-700` | `#454A47` | Secondary labels |
| `ink-500` | `#727873` | Tertiary metadata |
| `rule-200` | `#D7D8D2` | Structural dividers |
| `rule-300` | `#C5C8C1` | Strong dividers and control borders |
| `mineral-600` | `#1F7668` | Single brand accent and focus emphasis |
| `mineral-700` | `#165F54` | Pressed/selected accent |
| `positive-600` | `#2D7252` | Income/success, paired with `+` and a label |
| `negative-600` | `#A8453D` | Expense/error, paired with `−` and a label |
| `warning-600` | `#9A651D` | Review required or uncertain |
| `info-600` | `#426A86` | Informational state, not primary action |

#### Dark appearance

| Token | Value | Purpose |
|---|---:|---|
| `canvas-0-dark` | `#171A18` | Application background |
| `surface-0-dark` | `#1E211F` | Primary work surface |
| `surface-1-dark` | `#272B28` | Sidebar and recessed surfaces |
| `ink-950-dark` | `#F1F2ED` | Primary text |
| `ink-700-dark` | `#C5C9C4` | Secondary labels |
| `ink-500-dark` | `#969C96` | Tertiary metadata |
| `rule-200-dark` | `#343A36` | Structural dividers |
| `rule-300-dark` | `#454D48` | Strong dividers |
| `mineral-600-dark` | `#62B6A4` | Accent, desaturated for dark surfaces |
| `positive-600-dark` | `#71BE91` | Income/success |
| `negative-600-dark` | `#E18479` | Expense/error |
| `warning-600-dark` | `#D5A45B` | Review required |
| `info-600-dark` | `#82ADCA` | Informational state |

Semantic colors must pass WCAG AA for text at their actual sizes. Color never carries meaning alone.

### 4.2 Semantic tokens

- `background-app` → `canvas-0`
- `background-workspace` → `surface-0`
- `background-recessed` → `surface-1`
- `text-primary` → `ink-950`
- `text-secondary` → `ink-700`
- `text-tertiary` → `ink-500`
- `border-subtle` → `rule-200`
- `border-strong` → `rule-300`
- `action-primary` → `mineral-600`
- `focus-ring` → system focus ring, with `mineral-600` used only where custom focus is unavoidable
- `amount-inflow` → `positive-600`
- `amount-outflow` → `negative-600`
- `state-warning` → `warning-600`
- `state-information` → `info-600`

### 4.3 Component tokens

- **Sidebar selection:** system selection material with mineral accent indicator; no filled pill rows.
- **Transaction row:** transparent background, 1 px subtle rule, 8 px vertical and 12 px horizontal padding.
- **Inspector:** recessed background, 16 px section gap, 12 px field gap.
- **Primary button:** native bordered-prominent control; one per decision surface.
- **Destructive button:** native destructive role; never visually compete with the primary action.
- **Status badge:** 6 px vertical, 8 px horizontal, 6 px corner radius; label plus icon, never color alone.
- **Review panel:** 12 px corner radius, 1 px rule, no floating shadow unless presented as a sheet.

## 5. Typography and numeric treatment

### Production typography

- **Window title:** SF Pro Display, 26 px equivalent, semibold.
- **Section title:** SF Pro Text, 15 px, semibold.
- **Body:** SF Pro Text, 13 px regular.
- **Secondary:** SF Pro Text, 12 px regular.
- **Caption/metadata:** SF Pro Text, 11 px medium.
- **Money and counts:** SF Pro Text with tabular figures; use SF Mono only for hashes, receipt fragments, and developer-level identifiers.

Use Dynamic Type/system text styles where SwiftUI supports them. Never rasterize text into visual assets.

### Money rules

- Right-align amounts and decimal separators in tables.
- Always render the currency unit or establish it unambiguously in the column header/account context.
- Preserve source precision; do not add decorative decimals.
- Use `+` and `−` signs for direction. Do not rely on red/green.
- Never abbreviate a value if the abbreviation could change financial interpretation.
- Parentheses may represent negative accounting values only when a user setting explicitly selects that style.

## 6. Spacing, shape, and material

- Base unit: 4 px.
- Scale: 4, 8, 12, 16, 20, 24, 32, 48.
- Table row minimum: 28 px compact, 34 px comfortable. User preference may switch density.
- Primary content margin: 20 px; large empty/onboarding surfaces: 32 px.
- Inspector width: 300–380 px.
- Sidebar ideal width: 220–260 px.
- Main window minimum: 900 × 620 px for the complete workbench. Narrower windows collapse the inspector before truncating the ledger.
- Radius scale: 4 px controls, 8 px groups, 12 px sheets/review panels. Avoid bubble-shaped containers.
- Shadows: use native window/sheet shadow only. Within the app, use hierarchy, material, and rules before elevation.

## 7. Information architecture

The current thirteen equal sidebar destinations are a development inventory, not the final navigation.

### Primary sidebar

1. **Overview** — balances, upcoming obligations, budget status, recent activity.
2. **Transactions** — the canonical ledger and daily editing surface.
3. **Accounts** — account balances, reconciliation, account settings.
4. **Plans** — budgets, recurrence, and installments grouped under one parent.
5. **Reports** — accessible charts plus exact tables.

### Utility destinations

- **Search** is a global toolbar field and command, not a permanent peer destination.
- **Import & Migration** appears during onboarding and remains accessible from File > Import.
- **Backup & Restore** lives in File and Settings, with last-backup status in Overview.
- **Categories** are managed contextually from transaction editing and Settings.
- **Settings** remains a standard macOS Settings scene, not a detail-page row.

### Main transaction workspace

- Sidebar: product navigation and account filter.
- Main column: sortable transaction table with date, account, payee/note, category, status, and amount.
- Inspector: selected transaction details, provenance, links, recurrence/installment context, and revision history.
- Toolbar: New Transaction, filter/search, date range, density, inspector toggle.
- Status area: reconciliation state, visible result count, selection summary.

## 8. Core screens

### 8.1 Onboarding

Offer three plain choices: import Money Manager backup, open Ledger Atlas ledger, or create an empty local ledger. Explain local storage and read-only source handling in one sentence. Do not show feature marketing.

### 8.2 Import and migration review

Use a step-based flow: Select Source → Identify Profile → Review Coverage → Choose Timezone → Choose Destination → Approve. Show named compatibility level, mapped/preserved/excluded/blocked counts, unknown semantics, destination state, and source immutability. Blocked conditions must be prominent and content-free.

### 8.3 Transactions

The table is the daily home. Support multi-selection, contextual actions, column customization, sticky dates, fast entry, keyboard navigation, undo, and an optional inspector. Inline editing is limited to unambiguous fields; complex edits use a sheet or inspector.

### 8.4 Transaction editor

Use a single coherent form: kind, amount, account effects, category, date/time/timezone, note, tags, recurrence/installment association, and provenance. Transfer mode always shows both effects and any conversion/rounding rule. Validation appears beside the relevant field; failed saves change nothing.

### 8.5 Accounts and reconciliation

Show balance, currency, last reconciled balance/date, unreconciled count, and related activity. Reconciliation is a guided comparison, not a checkbox hidden in a row menu.

### 8.6 Plans

Budgets, recurrence, and installments share a planning workspace but retain distinct semantics. Use a timeline/list split, visible next occurrence, progress, exceptions, paused/completed states, and direct links to generated transactions.

### 8.7 Reports

Charts answer one question at a time and always provide the exact table used to derive them. Default to trends, category composition, cash flow, and budget variance. No 3D charts, gauges, decorative gradients, or unexplained net figures.

### 8.8 Backup and restore

Show last successful exact backup, destination, checksum verification, and restore validation. Imported ledgers must use exact canonical backup until a portable package can preserve the full provenance graph. Never label an unverified copy “safe.”

## 9. Interaction contract

### Keyboard

- `⌘N`: new transaction.
- `⌘F`: focus global search.
- `⌥⌘F`: open advanced filters.
- `⌘I`: toggle inspector.
- `⌘Z` / `⇧⌘Z`: undo/redo supported mutations.
- `Return`: edit selected row; `Space`: Quick Look details; `Delete`: confirmation for tombstone/archive.
- Arrow keys move table selection; Shift extends selection; Tab follows visual order.

Every command must also exist in a menu or visible control. Shortcuts are accelerators, not hidden capabilities.

### Motion

- 80–120 ms for control feedback; 160–220 ms for inspector and selection transitions.
- Use native spring/easing where it clarifies spatial change.
- No perpetual animation, shimmer after loading, bouncing icons, parallax, or animated money totals.
- Under Reduce Motion, crossfade only or remove transition entirely.

### Feedback

- Optimistic UI is allowed only when rollback is guaranteed and visible.
- Save success is quiet. Failure is explicit, field-local, and preserves the previous value.
- Long operations show phase, cancellability, and whether any write has occurred.
- Import and backup never use a generic spinner without explanatory text.

## 10. Accessibility and privacy

- Minimum target: 28 × 28 px on Mac; 44 × 44 px if a future touch client shares the design.
- Every chart has a navigable table and spoken summary.
- Every icon-only button has a label, help text, and keyboard equivalent.
- Focus never disappears after a mutation or validation error.
- Redacted import views never expose source paths, raw identifiers, notes, amounts, sidecar payloads, or private file names.
- Prototypes use synthetic accounts, payees, dates, and non-round amounts. Never paste a real backup or screenshot into an external design tool.

## 11. Content style

- Direct verbs: Import, Review, Approve, Save Backup, Reconcile.
- State the consequence: “Creates a local Ledger Atlas ledger. The source remains unchanged.”
- Avoid hype: seamless, effortless, revolutionize, unleash, smart finance, AI-powered money.
- Avoid blame: use “This backup profile is not yet certified,” not “Invalid backup.”
- Prefer “transaction,” “account,” “source,” “preserved,” and “blocked” consistently.
- Never promise universal compatibility or “1:1” without a named certification scope.

## 12. Empty, loading, and failure states

Every production surface must define:

- **No ledger:** one primary action to open, import, or create.
- **Empty ledger:** explain the difference from an unavailable ledger.
- **No search results:** preserve filters and offer clear reset.
- **Loading:** show the object and phase being loaded; use skeletons only if dimensions are stable.
- **Unavailable/corrupt:** clear previous bound data, disable mutation, explain recovery choices.
- **Partially displayable import:** show preserved but undisplayed count and link to coverage details.
- **Permission denied:** explain how to reselect the file without exposing its full path.

## 13. Anti-patterns

Never use:

- Purple/blue neon gradients, glowing buttons, glassmorphism everywhere, or pure black.
- A dashboard composed of equal rounded statistic cards.
- Huge marketing typography inside the working app.
- Floating action buttons, mobile tab bars, hamburger menus, or web-style fake title bars on macOS.
- Emoji as interface icons; use SF Symbols with text alternatives.
- Continuous motion, decorative confetti, animated charts on every navigation.
- Red/green as the only representation of financial direction.
- Hidden destructive gestures or a save that silently changes history.
- Fake precision, rounded sample metrics, generic stock names, or real user data in prototypes.
- Charts without exact tables, provenance hidden behind developer mode, or compatibility claims without evidence.

## 14. Prototype and implementation discipline

- Generate at least three materially different screen compositions before choosing one. Changing only color does not count.
- Prototype one complete journey: open/import → review → ledger → edit → search/report → backup.
- Treat generated HTML/CSS/Figma/Stitch code as disposable reference. Production remains native SwiftUI/AppKit.
- Keep prototype artifacts outside the accepted product tree until a direction is approved. Record the decision, not the discarded implementation.
- Validate the chosen direction with realistic synthetic dense, sparse, error, long-label, large-number, negative-number, and accessibility states.
- Do not change this design contract and judge a candidate against that changed contract in the same acceptance run.

## 15. Decision log

| Date | Decision | Rationale |
|---|---|---|
| 2026-08-20 | Adopt Quiet Financial Instrument | Native precision and calm command fit daily personal-finance work better than fintech spectacle. |
| 2026-08-20 | Use one mineral-green accent | Gives Ledger Atlas a distinct identity while keeping semantic financial colors legible. |
| 2026-08-20 | Use Apple system typography in production | Native legibility, accessibility, localization, and platform fit outweigh novelty. |
| 2026-08-20 | Replace thirteen peer destinations with five primary areas | Reduces development-inventory navigation and centers daily jobs. |
| 2026-08-20 | Keep provenance visible | Migration trust is a core product capability, not implementation metadata. |
