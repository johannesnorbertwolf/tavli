#!/usr/bin/env bash
# One-command setup for the TavliApp Xcode project:
#   1. ensure the bundled Core ML model (PlakotoValue.mlpackage) exists
#   2. ensure xcodegen is installed
#   3. generate TavliApp.xcodeproj from project.yml
#   4. resolve Swift Package dependencies
#
# Run from anywhere:
#   bash ios/TavliApp/setup.sh                # generate model only if missing
#   bash ios/TavliApp/setup.sh --force-model  # always regenerate the model
set -euo pipefail
cd "$(dirname "$0")"
HERE="$(pwd)"                       # …/ios/TavliApp
ROOT="$(cd ../.. && pwd)"           # repo root
MODEL="$HERE/TavliApp/Resources/PlakotoValue.mlpackage"

FORCE_MODEL=false
for arg in "$@"; do
  [ "$arg" = "--force-model" ] && FORCE_MODEL=true
done

# ── 1. Core ML model ─────────────────────────────────────────────────────────
# The value network ships as a gitignored, generated artifact. Without it the
# app silently falls back to random AI moves, so generate it before the project
# (the project only references the model if it exists at generation time).
if [ "$FORCE_MODEL" = true ] || [ ! -f "$MODEL/Manifest.json" ]; then
  echo "→ Generating Core ML model (PlakotoValue.mlpackage)…"
  if [ -x "$ROOT/.venv/bin/python" ]; then
    PY="$ROOT/.venv/bin/python"
  else
    PY="python3"
    echo "  (no .venv found; using python3 — it must have torch + coremltools)"
  fi
  ( cd "$ROOT" && PYTHONPATH=. "$PY" ios/scripts/convert_to_coreml.py )
else
  echo "→ Core ML model present (pass --force-model to regenerate)."
fi

# ── 2. xcodegen ──────────────────────────────────────────────────────────────
echo "→ Checking xcodegen…"
if ! command -v xcodegen &>/dev/null; then
  echo "  Installing xcodegen via Homebrew…"
  if ! command -v brew &>/dev/null; then
    echo "ERROR: Homebrew not found. Install it from https://brew.sh then re-run this script."
    exit 1
  fi
  brew install xcodegen
fi

# ── 3. Generate project ──────────────────────────────────────────────────────
echo "→ Generating TavliApp.xcodeproj…"
xcodegen generate

echo "→ Resolving Swift Package dependencies…"
xcodebuild -resolvePackageDependencies -project TavliApp.xcodeproj

echo ""
echo "Done. Next steps:"
echo "  1. open ios/TavliApp/TavliApp.xcodeproj"
echo "  2. Select an iPad simulator as the run destination"
echo "  3. Press ⌘R to build and run"
