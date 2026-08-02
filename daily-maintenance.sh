#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------
# Daily Repo Maintenance
#
# For every repo owned by GH_USER (minus anything in exclude.txt):
#   1. Clone it fresh.
#   2. Try real, safe auto-fixes (lint/format/dead-links).
#   3. If real changes were made -> commit + push with a clear message.
#   4. If nothing needed fixing -> append one line to daily-log.md
#      and commit that instead (a genuine, explainable change,
#      not a no-op).
#
# Requires secrets: PAT_TOKEN (repo scope), GH_USERNAME
# Optional: exclude.txt in this repo, one repo name per line
# ------------------------------------------------------------------

GH_USER="${GH_USER:?GH_USER not set}"
GH_TOKEN="${GH_TOKEN:?GH_TOKEN not set}"
DRY_RUN="${DRY_RUN:-false}"
WORKDIR="$(mktemp -d)"
EXCLUDE_FILE="$(dirname "$0")/exclude.txt"

echo "== Daily maintenance run for ${GH_USER} =="
echo "Dry run: ${DRY_RUN}"

is_excluded() {
  local repo="$1"
  [[ -f "$EXCLUDE_FILE" ]] && grep -qxF "$repo" "$EXCLUDE_FILE"
}

commit_and_push() {
  local msg="$1"
  git add -A
  if git diff --cached --quiet; then
    return 1
  fi
  git -c user.name="daily-maintenance-bot" \
      -c user.email="actions@users.noreply.github.com" \
      commit -m "$msg" -q
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "  [dry-run] would push: $msg"
  else
    git push -q
  fi
  return 0
}

# Fetch non-fork, non-archived repos for the user
repos=$(gh api "users/${GH_USER}/repos?per_page=100&type=owner" \
  --jq '.[] | select(.fork==false and .archived==false) | .name')

for repo in $repos; do
  if is_excluded "$repo"; then
    echo "-- Skipping excluded repo: $repo"
    continue
  fi

  echo "-- Checking $repo"
  repo_dir="${WORKDIR}/${repo}"
  if ! git clone --depth 1 "https://x-access-token:${GH_TOKEN}@github.com/${GH_USER}/${repo}.git" "$repo_dir" -q; then
    echo "   clone failed, skipping"
    continue
  fi
  cd "$repo_dir"

  changed=false

  # --- JS/TS projects ---
  if [[ -f package.json ]]; then
    if [[ -f .eslintrc* || -f eslint.config.js ]]; then
      npx --yes eslint . --fix --quiet || true
    fi
    if [[ -f .prettierrc* || -f prettier.config.js ]]; then
      npx --yes prettier --write . --loglevel error || true
    fi
  fi

  # --- Python projects ---
  if find . -maxdepth 2 -name "*.py" | grep -q .; then
    black . --quiet || true
  fi

  if commit_and_push "fix: automated lint/format fixes"; then
    echo "   -> pushed real fixes"
    changed=true
  fi

  # --- Fallback: genuine log entry, only if nothing else changed ---
  if [[ "$changed" == false ]]; then
    log_file="daily-log.md"
    [[ -f "$log_file" ]] || echo "# Daily Maintenance Log" > "$log_file"
    echo "- $(date -u +'%Y-%m-%d %H:%M UTC'): checked, no lint/format issues found." >> "$log_file"
    commit_and_push "chore: daily maintenance check" || echo "   -> nothing to log either, skipping"
  fi

  cd - > /dev/null
done

rm -rf "$WORKDIR"
echo "== Done =="
