#!/usr/bin/env bash
# ------------------------------------------------------------------
# lib/utils.sh — Shared utilities for daily-bot modules
#
# Sourced by daily-maintenance.sh before any module runs.
# Provides: commit_and_push, config helpers, logging, summary helpers.
# ------------------------------------------------------------------

# ---- Globals (set by orchestrator before sourcing) ----
# GH_USER, GH_TOKEN, DRY_RUN, WORKDIR, SCRIPT_DIR, SUMMARY_FILE

# ---- Summary / Logging ----

# Counters
TOTAL_REPOS=0
TOTAL_FIXES=0
TOTAL_ERRORS=0

init_summary() {
  SUMMARY_FILE="${SUMMARY_FILE:-${WORKDIR}/summary.json}"
  echo '[]' > "$SUMMARY_FILE"
}

# Append a structured entry to the summary JSON.
# Usage: log_summary "repo-name" "module" "action" "detail"
log_summary() {
  local repo="$1" module="$2" action="$3" detail="$4"
  local ts
  ts=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
  local entry
  entry=$(printf '{"ts":"%s","repo":"%s","module":"%s","action":"%s","detail":"%s"}' \
    "$ts" "$repo" "$module" "$action" "$detail")
  # Append to JSON array
  local tmp
  tmp=$(mktemp)
  if command -v python3 &>/dev/null && python3 -c "import sys" &>/dev/null; then
    python3 -c "
import json, sys
try:
    with open('$SUMMARY_FILE', 'r') as f:
        data = json.load(f)
    data.append(json.loads('''$entry'''))
    with open('$SUMMARY_FILE', 'w') as f:
        json.dump(data, f, indent=2)
except Exception:
    pass
" 2>/dev/null || echo "$entry" >> "${SUMMARY_FILE}.ndjson"
  elif command -v jq &>/dev/null; then
    jq --argjson e "$entry" '. += [$e]' "$SUMMARY_FILE" > "$tmp" 2>/dev/null && mv "$tmp" "$SUMMARY_FILE" || echo "$entry" >> "${SUMMARY_FILE}.ndjson"

  else
    # Fallback: append as newline-delimited JSON
    echo "$entry" >> "${SUMMARY_FILE}.ndjson"
  fi


}

log_info()  { echo "   [INFO]  $*"; }
log_warn()  { echo "   [WARN]  $*"; }
log_error() { echo "   [ERROR] $*"; TOTAL_ERRORS=$((TOTAL_ERRORS + 1)); }

# ---- Git helpers ----

commit_and_push() {
  local msg="$1"
  git add -A
  if git diff --cached --quiet; then
    return 1
  fi
  # Identity is set via git config --global in the workflow.
  # Using GIT_AUTHOR_* and GIT_COMMITTER_* ensures both match the GitHub account.
  GIT_AUTHOR_NAME="Param96" \
  GIT_AUTHOR_EMAIL="paramppatel100@gmail.com" \
  GIT_COMMITTER_NAME="Param96" \
  GIT_COMMITTER_EMAIL="paramppatel100@gmail.com" \
  git commit -m "$msg" -q
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "  [dry-run] would push: $msg"
  else
    git push -q
  fi
  TOTAL_FIXES=$((TOTAL_FIXES + 1))
  return 0
}

# Safe commit — used for formatting-only changes (ESLint, Prettier, Black).
# Always commits directly to the default branch (same as commit_and_push).
commit_and_push_safe() {
  local msg="$1"
  commit_and_push "$msg"
}

# Generate a diff preview of staged changes for PR body or logging.
diff_preview() {
  local max_lines="${1:-200}"
  local diff_output
  diff_output=$(git diff --cached --stat 2>/dev/null || true)
  local detailed
  detailed=$(git diff --cached 2>/dev/null | head -n "$max_lines" || true)
  if [[ -n "$detailed" ]]; then
    printf '%s\n\n```diff\n%s\n```' "$diff_output" "$detailed"
  else
    echo "$diff_output"
  fi
}

# Propose risky fixes as a pull request instead of committing directly.
# Usage: propose_as_pr "repo_name" "branch-suffix" "PR Title" "PR body text"
propose_as_pr() {
  local repo_name="$1"
  local branch_suffix="$2"
  local pr_title="$3"
  local pr_body="$4"
  local today
  today=$(date -u +'%Y-%m-%d')
  local branch_name="daily-bot/${branch_suffix}-${today}"

  git add -A
  if git diff --cached --quiet; then
    log_info "No changes to propose for ${repo_name}"
    return 1
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    local preview
    preview=$(diff_preview 100)
    echo "  [dry-run] would open PR '${pr_title}' on branch '${branch_name}'"
    echo "  [dry-run] diff preview:"
    echo "$preview"
    git checkout -- . 2>/dev/null || true
    git reset HEAD . -q 2>/dev/null || true
    return 0
  fi

  # Detect default branch
  local default_branch
  default_branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "main")

  # Check if a PR from this bot already exists for this branch
  local existing_pr
  existing_pr=$(gh pr list --head "$branch_name" --json number --jq '.[0].number' 2>/dev/null || true)
  if [[ -n "$existing_pr" && "$existing_pr" != "null" ]]; then
    log_info "PR #${existing_pr} already exists for ${branch_name} on ${repo_name}; skipping"
    git checkout -- . 2>/dev/null || true
    git reset HEAD . -q 2>/dev/null || true
    return 0
  fi

  # Create branch, commit, push, open PR
  git checkout -b "$branch_name" -q 2>/dev/null || {
    # Branch might exist remotely; try a fresh one with a counter
    branch_name="${branch_name}-$(date +%s)"
    git checkout -b "$branch_name" -q
  }

  GIT_AUTHOR_NAME="Param96" \
  GIT_AUTHOR_EMAIL="paramppatel100@gmail.com" \
  GIT_COMMITTER_NAME="Param96" \
  GIT_COMMITTER_EMAIL="paramppatel100@gmail.com" \
  git commit -m "$pr_title" -q

  git push -u origin "$branch_name" -q 2>/dev/null || {
    log_error "Failed to push branch ${branch_name} for ${repo_name}"
    git checkout "$default_branch" -q 2>/dev/null || true
    return 1
  }

  gh pr create \
    --base "$default_branch" \
    --head "$branch_name" \
    --title "$pr_title" \
    --body "$pr_body" \
    2>/dev/null || {
    log_warn "Failed to create PR for ${repo_name} (branch: ${branch_name})"
  }

  # Switch back to default branch
  git checkout "$default_branch" -q 2>/dev/null || true

  TOTAL_FIXES=$((TOTAL_FIXES + 1))
  log_info "Opened PR '${pr_title}' on ${repo_name} (branch: ${branch_name})"
  return 0
}

# Check CI status for a specific commit SHA.
# Returns: "success", "failure", "pending", or "none" (no CI configured)
check_ci_status() {
  local repo_name="$1"
  local commit_sha="$2"
  local gh_user="${GH_USER:-}"

  if [[ -z "$gh_user" || -z "$commit_sha" ]]; then
    echo "none"
    return 0
  fi

  api_throttle

  local status_json
  status_json=$(gh api "repos/${gh_user}/${repo_name}/commits/${commit_sha}/check-runs" \
    --jq '{total: .total_count, conclusion: [.check_runs[].conclusion], status: [.check_runs[].status]}' \
    2>/dev/null || echo '{"total":0}')

  local total
  total=$(echo "$status_json" | python3 -c "
import sys, json
d = json.loads(sys.stdin.read())
print(d.get('total', 0))
" 2>/dev/null || echo "0")

  if [[ "$total" == "0" ]]; then
    echo "none"
    return 0
  fi

  # Check if any are still running
  local has_pending
  has_pending=$(echo "$status_json" | python3 -c "
import sys, json
d = json.loads(sys.stdin.read())
statuses = d.get('status', [])
print('true' if any(s in ('queued','in_progress') for s in statuses) else 'false')
" 2>/dev/null || echo "false")

  if [[ "$has_pending" == "true" ]]; then
    echo "pending"
    return 0
  fi

  # Check conclusions
  local has_failure
  has_failure=$(echo "$status_json" | python3 -c "
import sys, json
d = json.loads(sys.stdin.read())
conclusions = d.get('conclusion', [])
print('true' if any(c in ('failure','timed_out','cancelled') for c in conclusions) else 'false')
" 2>/dev/null || echo "false")

  if [[ "$has_failure" == "true" ]]; then
    echo "failure"
  else
    echo "success"
  fi
}

# Revert a specific commit and push, then notify via webhook.
rollback_commit() {
  local repo_name="$1"
  local repo_dir="$2"
  local commit_sha="$3"

  local orig_dir
  orig_dir="$(pwd)"
  cd "$repo_dir" || return 1

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[dry-run] would revert commit ${commit_sha} on ${repo_name}"
    cd "$orig_dir" || true
    return 0
  fi

  git -c user.name="Param96" \
      -c user.email="paramppatel100@gmail.com" \
      revert --no-edit "$commit_sha" -q 2>/dev/null || {
    log_error "Failed to revert commit ${commit_sha} on ${repo_name}"
    cd "$orig_dir" || true
    return 1
  }

  git push -q 2>/dev/null || {
    log_error "Failed to push revert for ${commit_sha} on ${repo_name}"
    cd "$orig_dir" || true
    return 1
  }

  local msg="⚠️ Auto-reverted commit ${commit_sha:0:8} on ${repo_name} — CI was failing after bot fix."
  send_webhook "$msg"
  log_warn "$msg"
  log_summary "$repo_name" "rollback" "reverted" "Reverted commit ${commit_sha:0:8} due to CI failure"

  cd "$orig_dir" || true
  return 0
}

# ---- Rate Limit Awareness ----

# Check GitHub API rate limit and sleep if below threshold.
api_throttle() {
  local threshold="${1:-250}"

  local rate_json
  rate_json=$(gh api rate_limit --jq '.resources.core' 2>/dev/null || echo '{}')

  if [[ -z "$rate_json" || "$rate_json" == "{}" ]]; then
    return 0
  fi

  local remaining reset_ts
  remaining=$(echo "$rate_json" | python3 -c "
import sys, json
d = json.loads(sys.stdin.read())
print(d.get('remaining', 5000))
" 2>/dev/null || echo "5000")

  if (( remaining < threshold )); then
    reset_ts=$(echo "$rate_json" | python3 -c "
import sys, json, time
d = json.loads(sys.stdin.read())
reset = d.get('reset', 0)
wait = max(0, int(reset - time.time()) + 5)
print(wait)
" 2>/dev/null || echo "60")

    log_warn "API rate limit low (${remaining} remaining). Sleeping ${reset_ts}s until reset..."
    sleep "$reset_ts"
  fi
}

# Wrapper around gh api that checks rate limits before each call.
gh_api_safe() {
  api_throttle
  gh api "$@"
}

# ---- Per-repo config ----

# Self-healing config flag — set to true if repo config is malformed
_REPO_CFG_MALFORMED=""

# Reads a key from the repo's .daily-bot.yml (or falls back to default).
# Self-healing: if repo config is malformed YAML, falls back to defaults
# and logs the parse error clearly. Never aborts.
# Usage: cfg_get "lint.eslint" => "true"
cfg_get() {
  local key="$1"
  local repo_cfg=".daily-bot.yml"
  local default_cfg="${SCRIPT_DIR}/daily-bot.default.yml"
  local val=""

  if [[ -f "$repo_cfg" && -z "$_REPO_CFG_MALFORMED" ]]; then
    val=$(_yaml_read_safe "$repo_cfg" "$key")
    if [[ "$val" == "__YAML_PARSE_ERROR__" ]]; then
      # Self-healing: mark config as malformed, fall back to defaults
      _REPO_CFG_MALFORMED="true"
      local repo_name
      repo_name=$(basename "$(pwd)")
      log_warn "Malformed .daily-bot.yml in ${repo_name} — falling back to bot-wide defaults"
      log_summary "${repo_name}" "config" "parse_error" "WARNING: Malformed .daily-bot.yml — using defaults"
      val=""
    fi
  fi
  if [[ -z "$val" && -f "$default_cfg" ]]; then
    val=$(_yaml_read "$default_cfg" "$key")
  fi
  # Ultimate fallback
  echo "${val:-true}"
}

# Reset per-repo config state (called at start of each repo processing)
reset_repo_config() {
  _REPO_CFG_MALFORMED=""
}

# Internal: read a dot-path key from a YAML file.
_yaml_read() {
  local file="$1" key="$2"
  # Prefer yq if available
  if command -v yq &>/dev/null; then
    yq -r ".$key // empty" "$file" 2>/dev/null
    return
  fi
  # Fallback: python3 + PyYAML
  if command -v python3 &>/dev/null; then
    python3 -c "
import yaml, sys, functools
with open('$file') as f:
    d = yaml.safe_load(f) or {}
keys = '$key'.split('.')
val = functools.reduce(lambda c, k: (c or {}).get(k), keys, d)
if val is not None:
    print(val)
" 2>/dev/null
    return
  fi
  # Last resort: grep for simple flat keys (won't work for nested)
  grep -E "^\s*${key##*.}:" "$file" 2>/dev/null | head -1 | awk '{print $2}'
}

# Self-healing wrapper: returns __YAML_PARSE_ERROR__ on malformed YAML
_yaml_read_safe() {
  local file="$1" key="$2"
  local result
  # First, validate the YAML file is parseable
  if command -v python3 &>/dev/null; then
    if ! python3 -c "import yaml; yaml.safe_load(open('$file'))" 2>/dev/null; then
      echo "__YAML_PARSE_ERROR__"
      return
    fi
  elif command -v yq &>/dev/null; then
    if ! yq '.' "$file" >/dev/null 2>&1; then
      echo "__YAML_PARSE_ERROR__"
      return
    fi
  fi
  _yaml_read "$file" "$key"
}

# Check if a module is enabled in per-repo config.
# Usage: module_enabled "security" || return 0
module_enabled() {
  local module="$1"
  local val
  val=$(cfg_get "${module}.enabled")
  [[ "$val" == "true" ]]
}

# ---- Pagination helper ----

# Fetch all repos for a user, handling GitHub API pagination.
fetch_all_repos() {
  local user="$1"
  local page=1
  local per_page=100
  local all_repos=""

  while true; do
    api_throttle
    local batch
    batch=$(gh api "users/${user}/repos?per_page=${per_page}&page=${page}&type=owner" \
      --jq '.[] | select(.fork==false and .archived==false) | .name' 2>/dev/null)
    if [[ -z "$batch" ]]; then
      break
    fi
    all_repos="${all_repos}${all_repos:+$'\n'}${batch}"
    # If we got fewer than per_page, we've reached the end
    local count
    count=$(echo "$batch" | wc -l | tr -d ' ')
    if (( count < per_page )); then
      break
    fi
    page=$((page + 1))
  done

  echo "$all_repos"
}

# Fetch repo metadata as JSON (stars, forks, open_issues, description, topics).
fetch_repo_meta() {
  local user="$1" repo="$2"
  api_throttle
  gh api "repos/${user}/${repo}" --jq '{
    stars: .stargazers_count,
    forks: .forks_count,
    open_issues: .open_issues_count,
    description: (.description // ""),
    topics: (.topics // []),
    has_license: (.license != null),
    default_branch: .default_branch
  }' 2>/dev/null
}

# ---- Webhook notification (tiered) ----

# Send a webhook message. Used for routine notifications (batched in daily digest).
send_webhook() {
  local message="$1"
  local webhook_url="${WEBHOOK_URL:-}"
  if [[ -z "$webhook_url" ]]; then
    return 0
  fi
  # Works for both Discord and Slack webhooks
  curl -sfS -H "Content-Type: application/json" \
    -d "{\"content\": $(printf '%s' "$message" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))'), \"text\": $(printf '%s' "$message" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')}" \
    "$webhook_url" || log_warn "Webhook notification failed"
}

# Send a CRITICAL webhook alert immediately.
# Used for: exposed secrets, broken CI, failed auto-fix revert, stale secrets.
send_webhook_critical() {
  local message="$1"
  # Prefix with alarm emoji for critical alerts
  send_webhook "🚨 CRITICAL: ${message}"
}

# Queue a routine notification for the daily digest (append to file).
# These are NOT sent immediately — they are batched into the daily summary.
queue_routine_notification() {
  local message="$1"
  local digest_file="${WORKDIR:-/tmp}/routine-notifications.txt"
  echo "$(date -u +'%H:%M UTC') — ${message}" >> "$digest_file"
}
