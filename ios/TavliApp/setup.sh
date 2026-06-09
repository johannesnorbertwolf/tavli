#!/usr/bin/env bash
# One-command setup for the TavliApp Xcode project:
#   1. ensure the Python venv exists (creates it with uv if missing)
#   2. ensure the bundled Core ML model (PlakotoValue.mlpackage) exists
#   3. ensure xcodegen is installed
#   4. generate TavliApp.xcodeproj from project.yml
#   5. resolve Swift Package dependencies
#   6. open TavliApp.xcodeproj in Xcode
#
# Run from anywhere:
#   bash ios/TavliApp/setup.sh                # generate model only if missing
#   bash ios/TavliApp/setup.sh --force-model  # always regenerate the model
set -euo pipefail
cd "$(dirname "$0")"
HERE="$(pwd)"                       # …/ios/TavliApp

# Resolve the *main* worktree root, not just the current directory tree.
# In a git worktree, --git-common-dir points to the shared .git dir inside the
# main repo, so dirname of that is the main worktree root where .venv lives.
GIT_COMMON="$(git rev-parse --git-common-dir 2>/dev/null || true)"
if [ -n "$GIT_COMMON" ] && [ "$GIT_COMMON" != ".git" ]; then
  MAIN_ROOT="$(cd "$(dirname "$GIT_COMMON")" && pwd)"
else
  MAIN_ROOT="$(cd ../.. && pwd)"
fi
ROOT="$(cd ../.. && pwd)"           # worktree root (for PYTHONPATH etc.)
MODEL="$HERE/TavliApp/Resources/PlakotoValue.mlpackage"
VENV="$MAIN_ROOT/.venv"

FORCE_MODEL=false
for arg in "$@"; do
  [ "$arg" = "--force-model" ] && FORCE_MODEL=true
done

# ── 1. Python venv ────────────────────────────────────────────────────────────
if [ ! -x "$VENV/bin/python" ]; then
  echo "→ Creating Python venv at $VENV…"
  if command -v uv &>/dev/null; then
    uv venv "$VENV" --python 3.11
    uv pip install --python "$VENV/bin/python" torch numpy coremltools
  else
    echo "ERROR: uv not found. Install it (brew install uv) or create the venv manually:"
    echo "  python3.11 -m venv $VENV"
    echo "  $VENV/bin/pip install torch numpy coremltools"
    exit 1
  fi
else
  echo "→ Python venv present."
fi
PY="$VENV/bin/python"

# ── 2. Core ML model ─────────────────────────────────────────────────────────
# The value network ships as a gitignored, generated artifact. Without it the
# app silently falls back to random AI moves, so generate it before the project
# (the project only references the model if it exists at generation time).
if [ "$FORCE_MODEL" = true ] || [ ! -f "$MODEL/Manifest.json" ]; then
  echo "→ Generating Core ML model (PlakotoValue.mlpackage)…"
  ( cd "$ROOT" && PYTHONPATH=. "$PY" ios/scripts/convert_to_coreml.py )
else
  echo "→ Core ML model present (pass --force-model to regenerate)."
fi

# ── 3. xcodegen ──────────────────────────────────────────────────────────────
echo "→ Checking xcodegen…"
if ! command -v xcodegen &>/dev/null; then
  echo "  Installing xcodegen via Homebrew…"
  if ! command -v brew &>/dev/null; then
    echo "ERROR: Homebrew not found. Install it from https://brew.sh then re-run this script."
    exit 1
  fi
  brew install xcodegen
fi

# ── 4. Generate project ───────────────────────────────────────────────────────
echo "→ Generating TavliApp.xcodeproj…"
xcodegen generate

echo "→ Resolving Swift Package dependencies…"
xcodebuild -resolvePackageDependencies -project TavliApp.xcodeproj

# ── 5. Open in Xcode ─────────────────────────────────────────────────────────
echo "→ Opening TavliApp.xcodeproj…"
open TavliApp.xcodeproj
