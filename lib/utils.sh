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
  if command -v jq &>/dev/null; then
    jq --argjson e "$entry" '. += [$e]' "$SUMMARY_FILE" > "$tmp" && mv "$tmp" "$SUMMARY_FILE"
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
  git -c user.name="daily-maintenance-bot" \
      -c user.email="actions@users.noreply.github.com" \
      commit -m "$msg" -q
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "  [dry-run] would push: $msg"
  else
    git push -q
  fi
  TOTAL_FIXES=$((TOTAL_FIXES + 1))
  return 0
}

# ---- Per-repo config ----

# Reads a key from the repo's .daily-bot.yml (or falls back to default).
# Usage: cfg_get "lint.eslint" => "true"
# Requires: yq or python3+PyYAML for real parsing; falls back to grep.
cfg_get() {
  local key="$1"
  local repo_cfg=".daily-bot.yml"
  local default_cfg="${SCRIPT_DIR}/daily-bot.default.yml"
  local val=""

  if [[ -f "$repo_cfg" ]]; then
    val=$(_yaml_read "$repo_cfg" "$key")
  fi
  if [[ -z "$val" && -f "$default_cfg" ]]; then
    val=$(_yaml_read "$default_cfg" "$key")
  fi
  # Ultimate fallback
  echo "${val:-true}"
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

# ---- Webhook notification ----

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
