# AuraLocal development instructions — mandatory for every coding agent
Read AURALOCAL_HANDOFF.md BEFORE editing any application code.
Treat the "Must preserve" list as a feature contract, not suggestions.
Before committing changes to lib/, native/ios/, ios/ or pubspec.yaml:
1. Update AURALOCAL_HANDOFF.md with the new behavior, preserved behavior, tests, known regressions and outstanding device verification.
2. Add a dated entry under Change history describing what changed and what must NOT be removed.
3. Run existing contract tests and avoid silently deleting functionality.
4. Commit the handoff in the SAME commit as the code change.
CI rejects application-code commits without a handoff update. The tracked pre-commit hook automatically adds a dated draft change record from staged files and stages the handoff; replace the draft with accurate details before committing whenever possible.
For a new chat, read this file and AURALOCAL_HANDOFF.md first.
