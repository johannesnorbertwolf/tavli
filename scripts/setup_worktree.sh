#!/usr/bin/env bash
# Seed a new worktree with the main repo's trained model + scheduler state, and
# symlink the venv. Idempotent: existing files are left untouched, so experiment
# state in the worktree never gets overwritten by re-running this.

set -euo pipefail

git_common_dir="$(git rev-parse --git-common-dir)"
main_repo_root="$(cd "$(dirname "$git_common_dir")" && pwd)"
worktree_root="$(git rev-parse --show-toplevel)"

if [[ "$main_repo_root" == "$worktree_root" ]]; then
    echo "Already in the main repo; nothing to seed."
    exit 0
fi

cd "$worktree_root"

# Copy training state (an actual copy, so this worktree can diverge freely).
for f in trained_model.pth training_state.json; do
    if [[ -e "$f" ]]; then
        echo "Keeping existing $f"
    elif [[ -e "$main_repo_root/$f" ]]; then
        cp "$main_repo_root/$f" "$f"
        echo "Copied $f from $main_repo_root"
    else
        echo "No $f in main repo; skipping"
    fi
done

# Symlink the venv (shared, no point duplicating).
if [[ -e ".venv" ]]; then
    echo "Keeping existing .venv"
elif [[ -d "$main_repo_root/.venv" ]]; then
    ln -s "$main_repo_root/.venv" .venv
    echo "Linked .venv -> $main_repo_root/.venv"
fi
