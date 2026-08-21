# Ledger Atlas issue tracker

## Canonical identity

GitHub Issues in the private repository `praxstack/ledger-atlas` are the canonical work records. The issue number and URL are stable identifiers in plans, commits, reviews, and handoffs.

Linear project: `Ledger Atlas` in the `Prax Lannister` team. Linear is a planning and visibility mirror. Each Linear issue must include the canonical GitHub URL. Closing or changing scope starts in GitHub, then is mirrored in Linear.

The local Markdown pack at `.scratch/ledger-atlas-end-to-end/issues/` is the durable pre-publication and recovery copy. It is not independently triaged after publication.

## Publishing workflow

1. Draft or update the local Markdown ticket.
2. Search GitHub for an equivalent open or closed issue.
3. Create or update the GitHub issue with explicit blockers and observable acceptance criteria.
4. Create or update the Linear mirror, attach the GitHub URL, and reproduce dependency links.
5. Apply exactly one readiness label from `triage-labels.md`.
6. When work starts, link the implementation branch or task to the GitHub issue. Pull requests are delivery artifacts, not request intake.

## Synchronization

- GitHub title, body, acceptance criteria, close reason, and canonical status win conflicts.
- Linear owns planning order, assignee visibility, and project views.
- Dependency changes must be reflected in both trackers.
- A Linear issue must never imply completion when its GitHub issue remains open.
- No issue may authorize commit, push, merge, deploy, destructive work, or access to protected evidence; repository gates remain authoritative.

## Current endpoints

- GitHub: `https://github.com/praxstack/ledger-atlas`
- Linear: `https://linear.app/prax-lannister/project/ledger-atlas-e967c6d2afe0`
