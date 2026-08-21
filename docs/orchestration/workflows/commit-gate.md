# Workflow: exact staged-tree commit gate

1. The implementer stages only declared paths. The gate never calls `git add`.
2. Preflight requires a non-empty index, no tracked unstaged changes, intact protected evidence, enabled project hook path, and active authority for the exact atom.
3. Full verification runs after staging and records the staged tree, diff hash, and bounded log hash under `.git/orchestrion/`.
4. Provider review receives only the frozen criterion and exact text diff after secret, binary, and size checks. Structured output is schema and semantic validated.
5. P0 paths receive reviewer and red-team passes. Classification is derived from paths, not a caller flag.
6. The attestation binds all fresh passing receipts to the staged tree and diff.
7. The pre-commit hook revalidates the attestation. The gate spends/removes it after the commit attempt.

This is strong local evidence, not an unbypassable boundary. Required remote CI and protected branches are needed before integration.
