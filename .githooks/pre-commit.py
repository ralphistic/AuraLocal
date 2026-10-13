#!/usr/bin/env python3
"""Automatically keep the project history in sync with staged app changes."""
from datetime import datetime, timezone
from pathlib import Path
import subprocess

def git(*args):
    return subprocess.check_output(["git", *args], text=True).strip()

changed = git("diff", "--cached", "--name-only").splitlines()
app = [f for f in changed if f.startswith(("lib/", "native/ios/", "ios/")) or f == "pubspec.yaml"]
if not app:
    raise SystemExit(0)
handoff = Path("AURALOCAL_HANDOFF.md")
text = handoff.read_text(encoding="utf-8-sig")
date = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
entry = f"\n- {date}: Code changed in {', '.join(app)}. Preserve all Must preserve features. Confirm behavior and iPhone testing; review diff for regressions.\n"
if "## Automatic change history" not in text:
    text += "\n## Automatic change history\n"
text += entry
handoff.write_text(text, encoding="utf-8")
subprocess.check_call(["git", "add", "AURALOCAL_HANDOFF.md"])
