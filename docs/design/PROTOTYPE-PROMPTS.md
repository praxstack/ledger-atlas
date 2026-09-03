# Ledger Atlas Prototype Prompt Pack

These prompts are for design exploration only. They do not certify financial behavior, compatibility, or implementation completeness.

Before using any prompt:

1. Attach or paste the repository `DESIGN.md`.
2. Use synthetic data only. Never upload a real backup, private screenshot, account name, note, receipt, photo, or transaction value.
3. Ask for an original Ledger Atlas identity. Do not ask for a pixel copy of Money Manager or another product.
4. Generate at least three structurally different directions before choosing.
5. Treat generated code as disposable prototype material. Production is native SwiftUI and AppKit.

## 1. Shared product context

Paste this context before any screen-specific prompt:

```text
You are designing Ledger Atlas, a private, local-first native macOS personal-finance application. It helps a user import a supported Money Manager backup through an explicit review, maintain an exact canonical ledger, manage accounts, transfers, categories, budgets, recurrence, and installments, inspect provenance, search and report, and create verified backups.

The interface must feel like a quiet financial instrument: precise, calm, durable, keyboard-first, dense enough for daily work, and unmistakably native to macOS. It must not feel like a marketing dashboard, mobile app stretched onto desktop, cryptocurrency terminal, or generic AI SaaS product.

Read and obey the attached DESIGN.md as a strict visual and interaction contract. Where this prompt conflicts with DESIGN.md, DESIGN.md wins.

Use synthetic content only. Include non-round synthetic values, long and short labels, positive and negative amounts, multiple currencies, unresolved import rows, validation errors, empty states, and a partially displayable import. Never use real personal information.
```

## 2. Google Stitch master prompt

```text
Create a high-fidelity, interactive desktop prototype for Ledger Atlas using the attached DESIGN.md as a strict design-system contract.

Target a native macOS application at 1440 by 960, credible down to a 900 by 620 minimum window. Use macOS composition: traffic-light-safe title area, sidebar, toolbar, sortable transaction table, optional inspector, sheets, standard menus, focus rings, context menus, and keyboard-oriented workflows. Do not use browser chrome, mobile navigation, floating action buttons, or a web-app title bar.

First generate three materially different compositions, not three color themes:

A. Ledger-first: transaction table dominates, accounts filter the sidebar, inspector shows detail.
B. Overview-first: a restrained overview opens into the same ledger workspace, without a card-grid dashboard.
C. Timeline-first: date-grouped activity and plans share the main canvas while preserving table-grade precision.

For each direction, include the same realistic synthetic states so comparison is fair: two accounts in different currencies; inflow, outflow, transfer, corrected transaction, tombstone, recurrence, and installment linkage; a selected row with revision history and provenance; a content-free blocked import warning; a last verified backup status; compact and comfortable density; and light and dark appearance.

Apply the Quiet Financial Instrument direction from DESIGN.md. Use one mineral-green accent, tabular money, warm neutral surfaces, fine structural rules, restrained radius, and minimal functional motion. No neon, gradients, glassmorphism, equal statistic-card grids, decorative charts, oversized headings, or continuous animation.

Build a clickable journey: Onboarding to Select Backup to Import Review to Approve to Transactions to Edit Transaction to Search to Report to Verified Backup.

Make actions, states, labels, focus order, keyboard shortcuts, empty states, unavailable states, and destructive confirmations visible enough for an engineer to implement. Generate logical next screens only within this journey. Do not invent cloud sync, investment trading, AI financial advice, or universal compatibility.

After generation, critique each direction: Can a keyboard user complete the daily transaction loop? Are amount, currency, direction, timezone, provenance, and revision unambiguous? Does it behave like native Mac software? Can VoiceOver understand every icon and chart? Does any surface overclaim import support? Is the identity recognizable without decoration?

Return the three directions, clickable journey, token summary, and short tradeoff analysis. Do not choose a winner yet.
```

### Stitch convergence prompt

```text
Keep the selected direction's information architecture and interaction model. Do not merely polish pixels.

Create three focused refinements: scanning, editing, and trust. Improve table hierarchy and amount alignment; the relationship between row, inspector, edit sheet, validation, and undo; and import coverage, provenance, backup verification, and blocked-state comprehension.

Preserve the DESIGN.md palette, typography posture, spacing, and anti-patterns. Show compact, comfortable, dark, increased-contrast, Reduce Motion, and long-localized-label states. Highlight anything that cannot be implemented with native SwiftUI or AppKit controls.
```

## 3. ChatGPT Images concept-board prompt

```text
Create a four-panel high-fidelity product design board for Ledger Atlas, a native macOS personal-finance workbench. Follow the attached DESIGN.md exactly.

Panel 1: transaction workspace at 1440 by 960 with native sidebar, toolbar, precise transaction table, selected row, and contextual inspector.
Panel 2: import review showing named profile support, mapped, preserved, excluded, and blocked counts, source timezone, destination state, and one content-free blocked reason.
Panel 3: transfer editor showing two equal account effects, currency handling, date, time, timezone, category rules, note, provenance, and validation.
Panel 4: reports and backup, showing one restrained cash-flow chart with its exact accessible table and a last-verified exact-backup status.

Visual direction: Quiet Financial Instrument. Warm neutral canvas, nearly black charcoal text, one mineral-green accent, fine rules, restrained corners, native macOS materials, tabular money, minimal shadows, no pure black. Production uses SF Pro and SF Mono; approximate those metrics faithfully.

Use synthetic, clearly fictional, non-round amounts and neutral account labels such as Daily Account, Reserve Account, and Travel Card. Include light and dark appearance with consistent composition.

Hard bans: no copied screenshots, purple or blue neon, gradients, glass cards, crypto aesthetics, floating action button, mobile tab bar, equal three-card dashboard, fake percentage claims, decorative 3D chart, overlapping text, emojis, or stock photography.

The result must look plausible as a shipping Mac app, not a Dribbble fantasy. Every control needs a clear purpose and enough space for localization. Render legible interface text; if text cannot be rendered accurately, leave a clean placeholder region rather than inventing nonsense.
```

### ChatGPT image-edit prompt

```text
Edit only these parts of the attached Ledger Atlas concept:
[list exact changes]

Preserve the window composition, panel proportions, mineral-green accent, warm-neutral palette, typography scale, table columns, synthetic values, and all unaffected controls. Do not redesign the entire image. Do not add features, decorations, gradients, cards, glows, logos, or personal data.
```

## 4. ChatGPT or Codex interactive prototype prompt

This follows the prototype rule: a disposable artifact answers one specific question.

```text
Build a throwaway interactive prototype that answers:

Which native Mac composition makes transaction scanning, editing, provenance inspection, and import trust easiest without overwhelming a daily user?

Use the attached DESIGN.md. Mark the artifact PROTOTYPE. Keep all state in memory and use synthetic data only. Do not connect to a real database or backup.

Create one runnable prototype with three radically different variants selected from a visible switcher:
A. Ledger-first table and inspector.
B. Overview-to-ledger split.
C. Date timeline and contextual detail.

Each variant supports the same actions: select and multi-select transactions; create and edit a transaction; create a transfer with two effects; inspect revision history and provenance; apply and clear search and filters; review a blocked import; save a simulated verified backup; trigger empty, loading, validation-error, unavailable, and partially displayable states; and toggle density, appearance, Reduce Motion, and increased contrast.

Render the relevant state after every action. Include a small evaluation overlay with task time, action count, errors, and observer notes. Do not add persistence, analytics services, a component library, backend abstractions, or production tests.

End with a decision memo: the question, variant tradeoffs, accessibility failures, native-control mismatches, recommendation, production decisions, and prototype code to discard.
```

## 5. Screen prompts

Use these only after supplying the shared context and DESIGN.md.

### Onboarding and workspace creation

```text
Design Ledger Atlas onboarding as one calm native Mac window. Offer exactly three paths: Import Money Manager Backup, Open Ledger Atlas Ledger, Create Empty Local Ledger. Explain local-only storage and read-only source handling in one sentence. Include first-run, recent-ledger, permission-denied, and unsupported-backup states. One primary action at a time; no feature carousel or marketing illustration.
```

### Import review

```text
Design a six-step import review: Select Source, Identify Profile, Review Coverage, Choose Source Timezone, Choose Destination, Approve. Distinguish classified-only, reviewable, blocked, approved, committing, complete, and failed. Show named profile and compatibility level; mapped, preserved, excluded, and blocked counts; attachment status; timezone; destination binding; and source immutability. Never show paths, raw IDs, amounts, notes, sidecar payloads, or hashes by default. Offer an optional content-free technical disclosure. Enable approval only when every condition is satisfied.
```

### Transaction workspace

```text
Design the daily Ledger Atlas transaction workspace for a keyboard-heavy Mac user. Use a sortable, customizable table with date, status, account, payee or note, category, tags, and exact amount. Support multi-selection, date groups, sticky headers, context menus, column resizing, density, global search, advanced filters, and an inspector. Show direction through sign, text, and restrained semantic color. Include large and small exact values, multiple currencies, corrected rows, tombstones, linked transfers, scheduled rows, and partially displayable imported records.
```

### Transaction editor and transfer

```text
Design a native Mac transaction editor for income, expense, transfer, split, and adjustment without changing financial meaning. A transfer shows both account effects, equal value for same-currency transfer, explicit conversion and rounding for FX, and linked provenance. Put validation beside the relevant field. Keep date, civil time, timezone, source literal, category, tags, note, recurrence, installment, and revision meaning inspectable. Failed save leaves the previous transaction unchanged. Include undo, redo, and a clear tombstone or archive path.
```

### Accounts and reconciliation

```text
Design Accounts as a native list and detail workspace, not a card gallery. Each account shows currency, exact current balance, last reconciled balance and date, unreconciled count, and activity trend. The detail view includes transactions and a guided reconciliation flow comparing statement balance with canonical balance. Show mismatch, missing transfer counterpart, closed or tombstoned account, and multi-currency states.
```

### Budgets, recurrence, and installments

```text
Design one Plans workspace with three modes: Budgets, Recurrence, Installments. Use a timeline or list and contextual inspector. Show next occurrence, progress, exceptions, skipped dates, pause or resume, completed count, remaining installments, budget rollover, actual versus planned amount, and links to generated transactions. Avoid gamification, rings, confetti, or decoration that obscures exact values.
```

### Search and filters

```text
Design global ledger search as a native toolbar search field with an advanced filter popover. Support text or note, account, category, tag, kind, status, amount range, date range, recurrence or installment linkage, provenance, and displayability. Filters remain visible as removable tokens, are keyboard navigable, and can be saved locally. Show no-results without clearing the query and distinguish zero matches from unavailable data.
```

### Reports and insights

```text
Design Reports around four questions: cash-flow trend, category composition, account balance history, and budget variance. Each chart has an exact accessible table, stated date range, currency scope, filters, and reconciliation note. Show mixed-currency limitations rather than summing incompatible units. Use restrained lines or bars only; no 3D, gauges, animated reveals, gradients, or unexplained percentages.
```

### Backup and restore

```text
Design Backup and Restore as a trust surface. Show last verified exact backup, destination label, creation time, checksum verification, source-ledger identity, and restore drill status. Explain that imported ledgers require exact canonical SQLite backup until portable packages preserve the complete provenance graph. Show backup-in-progress, validation failure, destination already exists, source moved, partial-file cleanup, and successful reopen. Never call a backup safe before validation succeeds.
```

### Settings and accessibility

```text
Design a standard macOS Settings scene for ledger defaults, amount display, first weekday, date and time conventions, density, backup reminders, privacy, accessibility, and advanced diagnostics. Do not place destructive database operations among normal preferences. Show Full Keyboard Access, Reduce Motion, increased contrast, VoiceOver labels, localization expansion, and a reset that preserves financial data.
```

## 6. Prototype evaluation script

Give every prototype reviewer the same synthetic tasks:

1. Find a corrected expense from three months ago and inspect its previous revision.
2. Enter a same-currency transfer using only the keyboard.
3. Identify why an import is blocked and whether the source was changed.
4. Find every unreconciled transaction above a synthetic threshold in one account.
5. Pause a recurrence for one occurrence without changing history.
6. Confirm remaining installment payments and open the last generated transaction.
7. Compare a budget with actual spending and read the result through the accessible table.
8. Create a verified exact backup and confirm what can be restored.

Record completion, time, wrong turns, inaccessible controls, misunderstood financial meaning, and confidence. Reject a beautiful prototype that fails these tasks.

## 7. Design review prompt

```text
Review this Ledger Atlas prototype against DESIGN.md and the synthetic evaluation script. Be adversarial. Report only concrete failures or PASS.

Check native macOS conventions and keyboard completeness; exact money, currency, sign, timezone, linkage, revision, and provenance clarity; import truthfulness and privacy redaction; empty, loading, error, unavailable, and partially displayable states; VoiceOver names, focus order, contrast, Reduce Motion, and localization; information density and scan performance; whether the visuals can be built with SwiftUI or AppKit; copied vendor identity; AI design clichés; ornamental charts; and hidden destructive actions.

For each failure, name the screen, user consequence, and smallest design correction. Do not praise the design, invent capabilities, or treat visual polish as evidence of working financial behavior.
```

## 8. Production handoff prompt

```text
Translate the approved Ledger Atlas prototype into a production handoff for native SwiftUI and AppKit. Do not reuse generated web code.

Output:
1. screen hierarchy and navigation model;
2. reusable native components and the Apple control each wraps or composes;
3. primitive to semantic to component token mapping from DESIGN.md;
4. data required by each screen, without vendor schema leakage;
5. state machines for import, ledger open, edit, backup, and restore;
6. menu commands and keyboard shortcuts;
7. focus and VoiceOver order;
8. window-size and inspector-collapse behavior;
9. empty, loading, error, and unavailable states;
10. implementation slices ordered by the first complete daily user journey.

Flag every prototype element without a direct native equivalent. Prefer standard controls and the smallest custom rendering surface. Do not add dependencies, cloud services, AI advice, sync, or unsupported import behavior.
```

## 9. Acceptance rule

Select a direction only when it wins on the full task journey, not because one screenshot looks impressive. Keep accepted decisions in `DESIGN.md`; keep disposable prototype code and rejected variants outside the production branch.
