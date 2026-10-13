"""Fail CI when app changes are committed without updating the handoff."""
import subprocess
import sys

def git(*args):
    return subprocess.check_output(["git", *args], text=True).strip()

before = git("rev-parse", "HEAD^") if subprocess.run(["git", "rev-parse", "HEAD^"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0 else None
if before is None:
    sys.exit(0)
changed = set(git("diff", "--name-only", before, "HEAD").splitlines())
app = [f for f in changed if f.startswith(("lib/", "native/ios/", "ios/")) or f == "pubspec.yaml"]
if app and "AURALOCAL_HANDOFF.md" not in changed:
    print("ERROR: app code changed without updating AURALOCAL_HANDOFF.md in the same commit.")
    print("Changed app files:", ", ".join(app))
    sys.exit(1)
print("PASS: project handoff updated with application changes" if app else "PASS: no app feature changes")
