#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------
# Daily Repo Maintenance — Main Orchestrator
#
# Modular daily maintenance for all repos owned by GH_USER.
# Runs these modules in order per repo:
#   0. Rollback        (revert bot commits that broke CI)
#   1. Lint & Format   (safe auto-fix, direct commit)
#   2. Security        (risky fixes via PR, trivy scanning)
#   3. Code Quality    (risky fixes via PR, static analysis)
#   4. Test & Build    (validate repo after fixes)
#   5. Dependencies    (outdated deps via PR)
#   6. Repo Hygiene    (stale cleanup)
# Then runs a final reporting pass across all results.
#
# Supports:
#   - Pagination (handles >100 repos)
#   - Per-repo config (.daily-bot.yml)
#   - Parallel processing (GNU parallel, if available)
#   - Discord/Slack webhook notifications
#   - Rate-limit-aware API operations
#   - PR mode for risky auto-fixes
#   - Rollback trigger for CI-breaking commits
#
# Requires secrets: PAT_TOKEN (repo scope), GH_USERNAME
# Optional secrets: WEBHOOK_URL (Discord/Slack webhook)
# Optional: exclude.txt — one repo name per line
# ------------------------------------------------------------------

# ---- Config ----
export GH_USER="${GH_USER:?GH_USER not set}"
export GH_TOKEN="${GH_TOKEN:?GH_TOKEN not set}"
export DRY_RUN="${DRY_RUN:-false}"
export WEBHOOK_URL="${WEBHOOK_URL:-}"
export WORKDIR
WORKDIR="$(mktemp -d)"
export SCRIPT_DIR
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EXCLUDE_FILE="${SCRIPT_DIR}/exclude.txt"
PARALLEL_WORKERS="${PARALLEL_WORKERS:-4}"

# ---- Source shared utilities ----
# shellcheck source=lib/utils.sh
source "${SCRIPT_DIR}/lib/utils.sh"

# ---- Source all modules ----
for mod in "${SCRIPT_DIR}"/modules/*.sh; do
  # shellcheck source=/dev/null
  source "$mod"
done

# ---- Helpers ----

is_excluded() {
  local repo="$1"
  [[ -f "$EXCLUDE_FILE" ]] && grep -qxF "$repo" "$EXCLUDE_FILE"
}

process_repo() {
  local repo="$1"

  if is_excluded "$repo"; then
    echo "-- Skipping excluded repo: $repo"
    return 0
  fi

  echo "============================================="
  echo "-- Processing: $repo"
  echo "============================================="

  # Rate-limit check before processing each repo
  api_throttle

  local repo_dir="${WORKDIR}/${repo}"
  if ! git clone --depth 1 "https://x-access-token:${GH_TOKEN}@github.com/${GH_USER}/${repo}.git" "$repo_dir" -q 2>/dev/null; then
    log_error "Clone failed for $repo"
    log_summary "$repo" "clone" "error" "clone failed"
    return 0
  fi
  cd "$repo_dir"

  TOTAL_REPOS=$((TOTAL_REPOS + 1))

  # Reset per-repo config state (self-healing for malformed YAML)
  reset_repo_config

  # ---- Run modules ----

  # 0. Rollback — check if previous bot commit broke CI
  run_rollback "$repo" "$repo_dir" || true

  # 1. Lint & Format (safe auto-fix, direct commit)
  run_lint_format "$repo" "$repo_dir" || true

  # 2. Security checks (risky fixes via PR, trivy scanning)
  run_security "$repo" "$repo_dir" || true

  # 3. Code Quality (risky fixes via PR, static analysis)
  run_code_quality "$repo" "$repo_dir" || true

  # 4. Test & Build gate (validate repo after fixes)
  run_test_build "$repo" "$repo_dir" || true

  # 5. Dependency updates (outdated deps via PR)
  run_dependency_update "$repo" "$repo_dir" || true

  # 6. Repo Hygiene (stale cleanup)
  run_repo_hygiene "$repo" "$repo_dir" || true

  # 7. Per-repo stats collection for reporting
  run_reporting_per_repo "$repo" "$repo_dir" || true

  # ---- Fallback: genuine log entry if nothing else changed ----
  local log_file="daily-log.md"
  [[ -f "$log_file" ]] || echo "# Daily Maintenance Log" > "$log_file"
  echo "- $(date -u +'%Y-%m-%d %H:%M UTC'): maintenance check completed." >> "$log_file"
  commit_and_push "chore: daily maintenance check" || true

  cd - > /dev/null
  echo ""
}

# ---- Main ----

echo "====================================================="
echo "== Daily maintenance run for ${GH_USER}"
echo "== $(date -u +'%Y-%m-%d %H:%M UTC')"
echo "== Dry run: ${DRY_RUN}"
echo "====================================================="
echo ""

init_summary

# Fetch all repos with pagination
echo "-- Fetching repos..."
repos=$(fetch_all_repos "$GH_USER")
repo_count=$(echo "$repos" | grep -c . || echo "0")
echo "-- Found ${repo_count} repos to process"
echo ""

# Dynamic parallel worker adjustment based on rate limit
if command -v parallel &>/dev/null && [[ "$PARALLEL_WORKERS" -gt 1 ]]; then
  # Check rate limit and reduce workers if low
  local_remaining=$(gh api rate_limit --jq '.resources.core.remaining' 2>/dev/null || echo "5000")
  if (( local_remaining < 500 )); then
    PARALLEL_WORKERS=2
    echo "-- Rate limit low (${local_remaining} remaining), reducing to ${PARALLEL_WORKERS} workers"
  fi
  echo "-- Processing in parallel (${PARALLEL_WORKERS} workers)"
  export -f process_repo is_excluded run_lint_format run_security \
    run_repo_hygiene run_code_quality run_reporting_per_repo \
    run_rollback run_test_build run_dependency_update \
    commit_and_push commit_and_push_safe propose_as_pr diff_preview \
    check_ci_status rollback_commit api_throttle gh_api_safe \
    cfg_get _yaml_read module_enabled \
    log_summary log_info log_warn log_error \
    fetch_repo_meta send_webhook
  echo "$repos" | parallel -j "$PARALLEL_WORKERS" process_repo
else
  echo "-- Processing sequentially"
  for repo in $repos; do
    process_repo "$repo"
  done
fi

# ---- Final reporting ----
echo ""
echo "====================================================="
echo "== Running final reports"
echo "====================================================="

cd "$SCRIPT_DIR"
run_reporting_final || true

# ---- Cleanup ----
rm -rf "$WORKDIR"

echo ""
echo "====================================================="
echo "== Done! Repos: ${TOTAL_REPOS} | Fixes: ${TOTAL_FIXES} | Errors: ${TOTAL_ERRORS}"
echo "====================================================="
