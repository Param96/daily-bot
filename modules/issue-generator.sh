#!/usr/bin/env bash
# ------------------------------------------------------------------
# modules/issue-generator.sh — Automated issue generator for daily-bot
# ------------------------------------------------------------------

run_issue_generator() {
  local repo_name="$1"
  local repo_dir="$2"

  if ! module_enabled "issues"; then
    return 0
  fi

  if [[ "$(cfg_get "issues.auto_create_from_errors")" != "true" ]]; then
    return 0
  fi

  log_info "Running issue generator for $repo_name..."

  local orig_pwd
  orig_pwd="$(pwd)"
  cd "$repo_dir" || return 1

  # Read summary.json and ndjson to find WARNING or CRITICAL or error actions
  local summary_file="${SUMMARY_FILE:-${WORKDIR}/summary.json}"
  
  if ! command -v python3 &>/dev/null || ! command -v gh &>/dev/null; then
    log_warn "python3 or gh cli missing, skipping issue generator"
    cd "$orig_pwd" || return 0
    return 0
  fi

  # Extract errors for this repo
  local issues_to_create
  issues_to_create=$(python3 - "$repo_name" "$summary_file" "${summary_file}.ndjson" << 'PYEOF'
import sys, os, json

repo = sys.argv[1]
summary_file = sys.argv[2]
ndjson_file = sys.argv[3]

entries = []
for path in [summary_file, ndjson_file]:
    if os.path.exists(path) and os.path.getsize(path) > 0:
        try:
            with open(path, 'r', encoding='utf-8') as f:
                content = f.read().strip()
                if content.startswith('['):
                    entries.extend(json.loads(content))
                else:
                    for line in content.splitlines():
                        line = line.strip()
                        if line:
                            entries.append(json.loads(line))
        except Exception:
            pass

repo_entries = [e for e in entries if e.get('repo') == repo]
issues = []
for e in repo_entries:
    action = e.get('action', '').lower()
    detail = e.get('detail', '').lower()
    
    # Identify errors
    if action == 'error' or 'warning' in detail or 'critical' in detail or 'failed' in detail:
        title = f"daily-bot issue: {e.get('module')} - {e.get('action')}"
        body = f"Automated issue reported by daily-bot.\n\n**Module**: {e.get('module')}\n**Action**: {e.get('action')}\n**Details**: {e.get('detail')}"
        issues.append(json.dumps({'title': title, 'body': body}))

# Print one JSON per line to bash
for i in issues:
    print(i)
PYEOF
  )

  if [[ -n "$issues_to_create" ]]; then
    while IFS= read -r issue_json; do
      local title
      title=$(echo "$issue_json" | python3 -c "import sys, json; print(json.loads(sys.stdin.read()).get('title', ''))")
      local body
      body=$(echo "$issue_json" | python3 -c "import sys, json; print(json.loads(sys.stdin.read()).get('body', ''))")
      
      if [[ -z "$title" ]]; then
        continue
      fi

      # Check if an issue with similar title already exists
      local existing
      existing=$(gh issue list --state open --search "${title}" --json number --jq '.[0].number' 2>/dev/null || echo "")
      
      if [[ -z "$existing" || "$existing" == "null" ]]; then
        log_info "Creating issue: $title"
        if gh issue create --title "$title" --body "$body" --label "help wanted,bot" 2>/dev/null; then
           log_summary "$repo_name" "issues" "created" "Created issue: $title"
        else
           log_warn "Failed to create issue: $title"
        fi
      else
        log_info "Issue already exists for '$title' (#$existing)"
      fi
    done <<< "$issues_to_create"
  fi

  cd "$orig_pwd" || return 1
}
