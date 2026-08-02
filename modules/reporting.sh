#!/usr/bin/env bash
# ------------------------------------------------------------------
# modules/reporting.sh — Reporting and metrics module for daily-bot
#
# Generates reports after all repos have been processed.
# Sourced after lib/utils.sh is loaded by the orchestrator.
#
# Exposes entry-point functions:
#   run_reporting_per_repo(repo_name, repo_dir)
#   run_reporting_final()
# ------------------------------------------------------------------

# Primary entry point called per-repository to collect stats
run_reporting_per_repo() {
  local repo_name="$1"
  local repo_dir="$2"

  module_enabled "reporting" || return 0

  if [[ "$(cfg_get "reporting.collect_stats")" == "false" ]]; then
    return 0
  fi

  log_info "Collecting stats for repo: ${repo_name}"

  local today
  today=$(date -u +'%Y-%m-%d')

  local work_dir="${WORKDIR:-/tmp}"
  local gh_user="${GH_USER:-}"

  local meta_json=""
  if [[ -n "$gh_user" ]]; then
    meta_json=$(fetch_repo_meta "$gh_user" "$repo_name" 2>/dev/null || echo "")
  fi

  local stars=0 forks=0 open_issues=0
  if [[ -n "$meta_json" ]]; then
    if command -v jq &>/dev/null; then
      stars=$(echo "$meta_json" | jq -r '.stars // 0' 2>/dev/null || echo 0)
      forks=$(echo "$meta_json" | jq -r '.forks // 0' 2>/dev/null || echo 0)
      open_issues=$(echo "$meta_json" | jq -r '.open_issues // 0' 2>/dev/null || echo 0)
    elif command -v python3 &>/dev/null; then
      stars=$(python3 -c "import sys, json; print(json.loads(sys.stdin.read()).get('stars', 0))" <<< "$meta_json" 2>/dev/null || echo 0)
      forks=$(python3 -c "import sys, json; print(json.loads(sys.stdin.read()).get('forks', 0))" <<< "$meta_json" 2>/dev/null || echo 0)
      open_issues=$(python3 -c "import sys, json; print(json.loads(sys.stdin.read()).get('open_issues', 0))" <<< "$meta_json" 2>/dev/null || echo 0)
    fi
  fi

  # Append CSV row to ${WORKDIR}/repo-stats-today.csv: date,repo,stars,forks,open_issues
  mkdir -p "$work_dir"
  echo "${today},${repo_name},${stars},${forks},${open_issues}" >> "${work_dir}/repo-stats-today.csv"

  log_summary "$repo_name" "reporting" "collect_stats" "stars=${stars}, forks=${forks}, open_issues=${open_issues}"
}

# Alias for standard per-repo runner convention
run_reporting() {
  run_reporting_per_repo "$@"
}

# Secondary entry point called once after all repos are processed
run_reporting_final() {
  module_enabled "reporting" || return 0

  log_info "Running final reporting phase..."

  local today
  today=$(date -u +'%Y-%m-%d')
  local script_dir="${SCRIPT_DIR:-$(pwd)}"
  local work_dir="${WORKDIR:-/tmp}"

  # 1. Daily summary report
  if [[ "$(cfg_get "reporting.daily_summary")" != "false" ]]; then
    _reporting_generate_daily_summary "$today" "$script_dir" "$work_dir"
  fi

  # 2. Stats dashboard
  if [[ "$(cfg_get "reporting.stats_dashboard")" != "false" ]]; then
    _reporting_update_stats_dashboard "$script_dir" "$work_dir"
  fi

  # 3. Profile README update
  if [[ "$(cfg_get "reporting.profile_readme")" != "false" ]]; then
    _reporting_update_profile_readme "$today" "$work_dir"
  fi

  # 4. Webhook notification
  if [[ "$(cfg_get "reporting.webhook")" != "false" ]]; then
    _reporting_send_webhook "$today"
  fi
}

# Helper: Generate daily summary markdown report in daily-bot repo
_reporting_generate_daily_summary() {
  local today="$1"
  local script_dir="$2"
  local work_dir="$3"
  local summary_file="${SUMMARY_FILE:-${work_dir}/summary.json}"
  local report_dir="${script_dir}/reports"
  local report_path="${report_dir}/${today}.md"

  log_info "Generating daily summary report at reports/${today}.md"
  mkdir -p "$report_dir"

  if command -v python3 &>/dev/null; then
    python3 - "$today" "$summary_file" "${TOTAL_REPOS:-0}" "${TOTAL_FIXES:-0}" "${TOTAL_ERRORS:-0}" "$report_path" << 'EOF' || true
import sys, os, json
from collections import defaultdict

today = sys.argv[1]
summary_file = sys.argv[2]
total_repos = sys.argv[3]
total_fixes = sys.argv[4]
total_errors = sys.argv[5]
out_path = sys.argv[6]

entries = []
candidates = [summary_file, summary_file + ".ndjson"]
for path in candidates:
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

by_module = defaultdict(list)
for e in entries:
    mod = e.get('module', 'general')
    by_module[mod].append(e)

lines = []
lines.append(f"# Daily Maintenance Summary — {today}")
lines.append("")
lines.append("## Overview")
lines.append(f"- **Date:** {today}")
lines.append(f"- **Total Repos Checked:** {total_repos}")
lines.append(f"- **Total Fixes Pushed:** {total_fixes}")
lines.append(f"- **Total Errors:** {total_errors}")
lines.append("")
lines.append("## Module Breakdown")
lines.append("")

if not by_module:
    lines.append("No module actions recorded.")
else:
    for mod in sorted(by_module.keys()):
        lines.append(f"### {mod}")
        for item in by_module[mod]:
            repo = item.get('repo', 'unknown')
            action = item.get('action', 'info')
            detail = item.get('detail', '')
            lines.append(f"- **{repo}**: `{action}` — {detail}")
        lines.append("")

os.makedirs(os.path.dirname(out_path), exist_ok=True)
with open(out_path, 'w', encoding='utf-8') as f:
    f.write("\n".join(lines) + "\n")
EOF
  else
    cat << EOF > "$report_path"
# Daily Maintenance Summary — ${today}

- **Date:** ${today}
- **Total Repos Checked:** ${TOTAL_REPOS:-0}
- **Total Fixes Pushed:** ${TOTAL_FIXES:-0}
- **Total Errors:** ${TOTAL_ERRORS:-0}

## Module Breakdown
Report generated without Python details.
EOF
  fi

  local orig_pwd
  orig_pwd="$(pwd)"
  cd "$script_dir" || return 0
  commit_and_push "docs: generate daily summary report for ${today}" || true
  cd "$orig_pwd" || true
  log_summary "daily-bot" "reporting" "generate_daily_summary" "Report created at reports/${today}.md"
}

# Helper: Append today's stats rows to stats/repo-stats.csv in daily-bot repo
_reporting_update_stats_dashboard() {
  local script_dir="$1"
  local work_dir="$2"
  local today_csv="${work_dir}/repo-stats-today.csv"
  local stats_dir="${script_dir}/stats"
  local stats_csv="${stats_dir}/repo-stats.csv"

  if [[ ! -f "$today_csv" ]]; then
    log_info "No today repo stats file found at ${today_csv}."
    return 0
  fi

  log_info "Updating stats dashboard at stats/repo-stats.csv"
  mkdir -p "$stats_dir"
  if [[ ! -f "$stats_csv" ]]; then
    echo "date,repo,stars,forks,open_issues" > "$stats_csv"
  fi

  cat "$today_csv" >> "$stats_csv"

  local orig_pwd
  orig_pwd="$(pwd)"
  cd "$script_dir" || return 0
  commit_and_push "chore: update daily repo stats dashboard" || true
  cd "$orig_pwd" || true
  log_summary "daily-bot" "reporting" "update_stats_dashboard" "Appended today's stats to stats/repo-stats.csv"
}

# Helper: Update GitHub profile README with daily-bot stats
_reporting_update_profile_readme() {
  local today="$1"
  local work_dir="$2"

  local gh_user="${GH_USER:-}"
  local gh_token="${GH_TOKEN:-}"

  if [[ -z "$gh_user" || -z "$gh_token" ]]; then
    log_warn "GH_USER or GH_TOKEN not configured; skipping profile README update."
    return 0
  fi

  log_info "Updating profile README for ${gh_user}"

  local profile_dir="${work_dir}/profile-readme"
  rm -rf "$profile_dir"
  git clone --depth 1 "https://x-access-token:${gh_token}@github.com/${gh_user}/${gh_user}.git" "$profile_dir" -q || true

  if [[ ! -d "$profile_dir" ]]; then
    log_warn "Could not clone profile repo ${gh_user}/${gh_user}; skipping update."
    return 0
  fi

  local readme_file="${profile_dir}/README.md"
  if [[ ! -f "$readme_file" && -f "${profile_dir}/readme.md" ]]; then
    readme_file="${profile_dir}/readme.md"
  fi

  local csv_path="${work_dir}/repo-stats-today.csv"

  if command -v python3 &>/dev/null; then
    python3 - "$today" "${TOTAL_REPOS:-0}" "${TOTAL_FIXES:-0}" "$gh_user" "$csv_path" "$readme_file" << 'EOF' || true
import sys, os, csv, re

today = sys.argv[1]
total_repos = sys.argv[2]
total_fixes = sys.argv[3]
gh_user = sys.argv[4]
csv_path = sys.argv[5]
readme_path = sys.argv[6]

repos = []
if os.path.exists(csv_path):
    try:
        with open(csv_path, 'r', encoding='utf-8') as f:
            reader = csv.reader(f)
            for row in reader:
                if len(row) >= 5:
                    try:
                        repos.append({
                            'name': row[1],
                            'stars': int(row[2]),
                            'forks': int(row[3]),
                            'issues': int(row[4])
                        })
                    except ValueError:
                        pass
    except Exception:
        pass

repos.sort(key=lambda x: x['stars'], reverse=True)
top_repos = repos[:5]

stats_block = []
stats_block.append("<!-- DAILY-BOT:START -->")
stats_block.append("### 🤖 Daily Maintenance Stats")
stats_block.append(f"- **Last Run:** {today}")
stats_block.append(f"- **Total Repos Maintained:** {total_repos}")
stats_block.append(f"- **Today's Fixes:** {total_fixes}")
stats_block.append("")
stats_block.append("#### Top Repositories")
if top_repos:
    stats_block.append("| Repository | ⭐ Stars | 🍴 Forks | 🐛 Issues |")
    stats_block.append("| :--- | :--- | :--- | :--- |")
    for r in top_repos:
        name = r['name']
        url = f"https://github.com/{gh_user}/{name}"
        stats_block.append(f"| [{name}]({url}) | {r['stars']} | {r['forks']} | {r['issues']} |")
else:
    stats_block.append("No repository stats available.")
stats_block.append("<!-- DAILY-BOT:END -->")

new_section = "\n".join(stats_block)

content = ""
if os.path.exists(readme_path):
    with open(readme_path, 'r', encoding='utf-8') as f:
        content = f.read()

pattern = r'<!-- DAILY-BOT:START -->.*?<!-- DAILY-BOT:END -->'
if re.search(pattern, content, flags=re.DOTALL):
    new_content = re.sub(pattern, new_section, content, flags=re.DOTALL)
else:
    if content and not content.endswith('\n'):
        content += '\n'
    new_content = content + ("\n" if content else "") + new_section + "\n"

os.makedirs(os.path.dirname(readme_path), exist_ok=True)
with open(readme_path, 'w', encoding='utf-8') as f:
    f.write(new_content)
EOF
  fi

  local orig_pwd
  orig_pwd="$(pwd)"
  cd "$profile_dir" || return 0
  commit_and_push "docs: update daily-bot status in profile README" || true
  cd "$orig_pwd" || true

  log_summary "${gh_user}/${gh_user}" "reporting" "update_profile_readme" "Updated profile README stats section"
}

# Helper: Send summary via webhook
_reporting_send_webhook() {
  local today="$1"
  local msg="[Daily Maintenance Bot] Summary for ${today}: Repos checked: ${TOTAL_REPOS:-0}, Fixes pushed: ${TOTAL_FIXES:-0}, Errors: ${TOTAL_ERRORS:-0}"
  send_webhook "$msg" || true
  log_summary "daily-bot" "reporting" "send_webhook" "Sent webhook summary notification"
}
