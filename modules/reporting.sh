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
#
# Features:
#   - Daily summary markdown reports
#   - Stats dashboard (CSV)
#   - Profile README update with health scores
#   - Per-repo health score (0-100)
#   - Weekly digest aggregation
#   - Webhook notifications
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

  # Compute health score if enabled
  local health_score="-"
  if [[ "$(cfg_get "reporting.health_score")" != "false" ]]; then
    health_score=$(_compute_health_score "$repo_name")
  fi

  # ----------------------------------------------------------------
  # CHANGELOG generation
  # ----------------------------------------------------------------
  if [[ "$(cfg_get "reporting.changelog")" == "true" ]]; then
    log_info "Generating CHANGELOG for ${repo_name}..."
    local changelog_file="CHANGELOG.md"
    local temp_cl
    temp_cl=$(mktemp)
    
    # Get commits in the last 24 hours that follow conventional commits
    local recent_commits
    recent_commits=$(git log --since="24 hours ago" --no-merges --format="- %s (%h)" 2>/dev/null | grep -E '^(feat|fix|chore|docs|style|refactor|perf|test):' || true)
    
    if [[ -n "$recent_commits" ]]; then
      echo "## [$(date -u +'%Y-%m-%d')] - Automated daily update" > "$temp_cl"
      echo "" >> "$temp_cl"
      echo "$recent_commits" >> "$temp_cl"
      echo "" >> "$temp_cl"
      
      if [[ -f "$changelog_file" ]]; then
        cat "$changelog_file" >> "$temp_cl"
      fi
      mv "$temp_cl" "$changelog_file"
      
      if commit_and_push "docs: generate daily CHANGELOG"; then
        log_summary "$repo_name" "reporting" "changelog" "Generated CHANGELOG.md with recent commits"
      else
        log_summary "$repo_name" "reporting" "changelog" "CHANGELOG.md already up to date"
      fi
    else
      rm -f "$temp_cl"
      log_info "No conventional commits in the last 24h for ${repo_name}"
    fi
  fi

  # Append CSV row: date,repo,stars,forks,open_issues,health_score
  mkdir -p "$work_dir"
  echo "${today},${repo_name},${stars},${forks},${open_issues},${health_score}" >> "${work_dir}/repo-stats-today.csv"

  log_summary "$repo_name" "reporting" "collect_stats" "stars=${stars}, forks=${forks}, open_issues=${open_issues}, health=${health_score}"
}

# Alias for standard per-repo runner convention
run_reporting() {
  run_reporting_per_repo "$@"
}

# Compute a health score (0-100) for a repo based on summary data.
# Weights:
#   Lint clean:        20%
#   Zero vulns:        20%
#   No stale branches: 15%
#   No stale issues:   10%
#   Tests pass:        25%
#   README exists:      5%
#   License exists:     5%
_compute_health_score() {
  local repo_name="$1"
  local summary_file="${SUMMARY_FILE:-${WORKDIR}/summary.json}"
  local score=0

  if ! command -v python3 &>/dev/null; then
    echo "100"
    return 0
  fi

  score=$(python3 - "$repo_name" "$summary_file" "${summary_file}.ndjson" << 'PYEOF'
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

# Filter entries for this repo
repo_entries = [e for e in entries if e.get('repo') == repo]

def has_action(module, action_keyword):
    """Check if any entry for this repo+module contains the keyword."""
    for e in repo_entries:
        if e.get('module') == module:
            detail = (e.get('detail', '') + ' ' + e.get('action', '')).lower()
            if action_keyword.lower() in detail:
                return True
    return False

def has_module(module):
    return any(e.get('module') == module for e in repo_entries)

score = 0.0

# Lint clean (20%) — no fixes needed means clean
if has_module('lint-format'):
    if has_action('lint-format', 'clean') or has_action('lint-format', 'no lint'):
        score += 20
    elif has_action('lint-format', 'fixed'):
        score += 10  # Half credit — fixable but wasn't clean
else:
    score += 20  # No lint module means no JS/Python — full credit

# Zero vulnerabilities (20%)
vuln_found = False
for mod in ['security']:
    for e in repo_entries:
        if e.get('module') == mod:
            detail = e.get('detail', '').lower()
            if 'warning' in detail or 'vulnerabilit' in detail or 'secret' in detail:
                vuln_found = True
                break
if not vuln_found:
    score += 20

# No stale branches (15%)
stale_branch_found = False
for e in repo_entries:
    if e.get('module') == 'hygiene' and 'stale' in e.get('action', '').lower():
        detail = e.get('detail', '').lower()
        if 'branch' in detail and ('deleted' in detail or 'cleaned' in detail):
            stale_branch_found = True
            break
if not stale_branch_found:
    score += 15

# No stale issues (10%)
stale_issue_found = False
for e in repo_entries:
    if e.get('module') == 'hygiene':
        detail = e.get('detail', '').lower()
        if 'stale' in detail and ('issue' in detail or 'pr' in detail or 'labeled' in detail):
            stale_issue_found = True
            break
if not stale_issue_found:
    score += 10

# Tests pass (25%)
if has_module('testing'):
    if has_action('testing', 'passed') or has_action('testing', 'build_passed') or has_action('testing', 'test_passed'):
        if not (has_action('testing', 'failed') or has_action('testing', 'build_failed') or has_action('testing', 'test_failed')):
            score += 25
        else:
            score += 10  # Partial — some passed, some failed
    elif not has_action('testing', 'failed'):
        score += 25  # No test failures reported
else:
    score += 25  # No testing module — full credit (no tests to fail)

# README exists (5%)
if has_action('security', 'license file present') or has_action('hygiene', 'readme'):
    # Check for README warning
    readme_missing = False
    for e in repo_entries:
        if e.get('module') == 'hygiene':
            detail = e.get('detail', '').lower()
            if 'no readme' in detail or 'readme' in detail and 'warning' in detail:
                readme_missing = True
    if not readme_missing:
        score += 5
else:
    score += 5  # No hygiene check — assume present

# License exists (5%)
license_ok = True
for e in repo_entries:
    if e.get('module') == 'security' and e.get('action') == 'license_check':
        if 'warning' in e.get('detail', '').lower() or 'no license' in e.get('detail', '').lower():
            license_ok = False
if license_ok:
    score += 5

print(int(round(score)))
PYEOF
  ) || score=100

  echo "$score"
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

  # 5. Weekly digest (if today is the configured day)
  if [[ "$(cfg_get "reporting.weekly_digest")" != "false" ]]; then
    _reporting_send_weekly_digest "$today" "$script_dir" "$work_dir"
  fi

  # 6. SVG Dashboard
  if [[ "$(cfg_get "reporting.dashboard_svg")" == "true" ]]; then
    _reporting_generate_dashboard "$today" "$script_dir" "$work_dir"
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
    python3 - "$today" "$summary_file" "${TOTAL_REPOS:-0}" "${TOTAL_FIXES:-0}" "${TOTAL_ERRORS:-0}" "$report_path" "${work_dir}/repo-stats-today.csv" << 'EOF' || true
import sys, os, json, csv
from collections import defaultdict

today = sys.argv[1]
summary_file = sys.argv[2]
total_repos = sys.argv[3]
total_fixes = sys.argv[4]
total_errors = sys.argv[5]
out_path = sys.argv[6]
stats_csv = sys.argv[7] if len(sys.argv) > 7 else ""

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

# Read health scores from CSV
health_scores = {}
if stats_csv and os.path.exists(stats_csv):
    try:
        with open(stats_csv, 'r', encoding='utf-8') as f:
            for row in csv.reader(f):
                if len(row) >= 6 and row[5] != '-':
                    try:
                        health_scores[row[1]] = int(row[5])
                    except ValueError:
                        pass
    except Exception:
        pass

lines = []
lines.append(f"# Daily Maintenance Summary — {today}")
lines.append("")
lines.append("## Overview")
lines.append(f"- **Date:** {today}")
lines.append(f"- **Total Repos Checked:** {total_repos}")
lines.append(f"- **Total Fixes Pushed:** {total_fixes}")
lines.append(f"- **Total Errors:** {total_errors}")
lines.append("")

# Health score summary
if health_scores:
    lines.append("## Health Scores")
    lines.append("")
    lines.append("| Repository | Score | Status |")
    lines.append("| :--- | :---: | :--- |")
    for repo, score in sorted(health_scores.items(), key=lambda x: x[1]):
        if score >= 90:
            status = "🟢 Excellent"
        elif score >= 70:
            status = "🟡 Good"
        elif score >= 50:
            status = "🟠 Fair"
        else:
            status = "🔴 Needs Attention"
        bar_len = score // 10
        bar = "█" * bar_len + "░" * (10 - bar_len)
        lines.append(f"| {repo} | {bar} {score} | {status} |")
    lines.append("")
    avg = sum(health_scores.values()) // max(len(health_scores), 1)
    lines.append(f"**Average Health Score:** {avg}/100")
    lines.append("")

lines.append("## Module Breakdown")
lines.append("")

if not by_module:
    lines.append("No module actions recorded.")
else:
    # Highlight new security features, hygiene, quality
    for mod in sorted(by_module.keys()):
        lines.append(f"### {mod.capitalize()}")
        for item in by_module[mod]:
            repo = item.get('repo', 'unknown')
            action = item.get('action', 'info')
            detail = item.get('detail', '')
            
            # Format critical issues differently
            if 'WARNING' in detail or 'CRITICAL' in detail:
                lines.append(f"- ⚠️ **{repo}**: `{action}` — **{detail}**")
            elif action == 'sbom':
                lines.append(f"- 📦 **{repo}**: `{action}` — {detail}")
            elif action == 'secret_rotation':
                lines.append(f"- 🔑 **{repo}**: `{action}` — {detail}")
            elif action == 'branch_protection':
                lines.append(f"- 🛡️ **{repo}**: `{action}` — {detail}")
            elif action == 'orphaned_repo':
                lines.append(f"- 👻 **{repo}**: `{action}` — {detail}")
            elif action in ['radon', 'jscpd', 'depcheck', 'vulture']:
                lines.append(f"- 📊 **{repo}**: `{action}` — {detail}")
            else:
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
    echo "date,repo,stars,forks,open_issues,health_score" > "$stats_csv"
  fi

  cat "$today_csv" >> "$stats_csv"

  local orig_pwd
  orig_pwd="$(pwd)"
  cd "$script_dir" || return 0
  commit_and_push "chore: update daily repo stats dashboard" || true
  cd "$orig_pwd" || true
  log_summary "daily-bot" "reporting" "update_stats_dashboard" "Appended today's stats to stats/repo-stats.csv"
}

# Helper: Update GitHub profile README with daily-bot stats and health scores
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
                if len(row) >= 6:
                    try:
                        health = int(row[5]) if row[5] != '-' else 0
                        repos.append({
                            'name': row[1],
                            'stars': int(row[2]),
                            'forks': int(row[3]),
                            'issues': int(row[4]),
                            'health': health
                        })
                    except ValueError:
                        pass
    except Exception:
        pass

repos.sort(key=lambda x: x['stars'], reverse=True)
top_repos = repos[:5]

# Health score bar using Unicode blocks
def health_bar(score):
    filled = score // 10
    return "█" * filled + "░" * (10 - filled)

def health_emoji(score):
    if score >= 90: return "🟢"
    elif score >= 70: return "🟡"
    elif score >= 50: return "🟠"
    else: return "🔴"

avg_health = sum(r['health'] for r in repos) // max(len(repos), 1) if repos else 0

stats_block = []
stats_block.append("<!-- DAILY-BOT:START -->")
stats_block.append("### 🤖 Daily Maintenance Stats")
stats_block.append(f"- **Last Run:** {today}")
stats_block.append(f"- **Total Repos Maintained:** {total_repos}")
stats_block.append(f"- **Today's Fixes:** {total_fixes}")
stats_block.append(f"- **Average Health Score:** {health_emoji(avg_health)} {avg_health}/100")
stats_block.append("")
stats_block.append("#### Top Repositories")
if top_repos:
    stats_block.append("| Repository | ⭐ Stars | 🍴 Forks | 🐛 Issues | Health |")
    stats_block.append("| :--- | :--- | :--- | :--- | :--- |")
    for r in top_repos:
        name = r['name']
        url = f"https://github.com/{gh_user}/{name}"
        h = r['health']
        stats_block.append(f"| [{name}]({url}) | {r['stars']} | {r['forks']} | {r['issues']} | {health_emoji(h)} {health_bar(h)} {h} |")
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

# Helper: Generate and send weekly digest (runs only on configured day)
_reporting_send_weekly_digest() {
  local today="$1"
  local script_dir="$2"
  local work_dir="$3"

  # Check if today is the configured digest day (default: Monday = 1)
  local digest_day
  digest_day=$(cfg_get "reporting.weekly_digest_day")
  [[ -z "$digest_day" ]] && digest_day=1

  local today_dow
  today_dow=$(date -u +%u)  # 1=Monday, 7=Sunday

  if [[ "$today_dow" != "$digest_day" ]]; then
    return 0
  fi

  log_info "Generating weekly digest..."

  local report_dir="${script_dir}/reports"
  local weekly_dir="${report_dir}/weekly"
  mkdir -p "$weekly_dir"

  local week_num
  week_num=$(date -u +%V)
  local year
  year=$(date -u +%Y)
  local weekly_path="${weekly_dir}/${year}-W${week_num}.md"

  if command -v python3 &>/dev/null; then
    python3 - "$today" "$report_dir" "$weekly_path" "${script_dir}/stats/repo-stats.csv" << 'PYEOF' || true
import sys, os, json, csv, glob
from datetime import datetime, timedelta
from collections import defaultdict

today_str = sys.argv[1]
report_dir = sys.argv[2]
weekly_path = sys.argv[3]
stats_csv = sys.argv[4]

today = datetime.strptime(today_str, '%Y-%m-%d')

# Collect last 7 days of daily reports
lines = []
lines.append(f"# Weekly Digest — Week of {today_str}")
lines.append("")

total_fixes_week = 0
total_errors_week = 0
total_repos_week = 0
daily_summaries = []

for i in range(7):
    d = today - timedelta(days=i)
    date_str = d.strftime('%Y-%m-%d')
    report_path = os.path.join(report_dir, f"{date_str}.md")
    if os.path.exists(report_path):
        with open(report_path, 'r', encoding='utf-8') as f:
            content = f.read()
        # Extract stats from report
        for line in content.splitlines():
            if 'Total Repos Checked:' in line:
                try:
                    total_repos_week += int(line.split('**')[-1].strip() if '**' in line else '0')
                except ValueError:
                    pass
            if 'Total Fixes Pushed:' in line:
                try:
                    total_fixes_week += int(line.split('**')[-1].strip() if '**' in line else '0')
                except ValueError:
                    pass
            if 'Total Errors:' in line:
                try:
                    total_errors_week += int(line.split('**')[-1].strip() if '**' in line else '0')
                except ValueError:
                    pass
        daily_summaries.append(date_str)

lines.append("## Overview")
lines.append(f"- **Period:** {(today - timedelta(days=6)).strftime('%Y-%m-%d')} to {today_str}")
lines.append(f"- **Days with Reports:** {len(daily_summaries)}")
lines.append(f"- **Total Repos Processed (cumulative):** {total_repos_week}")
lines.append(f"- **Total Fixes Pushed:** {total_fixes_week}")
lines.append(f"- **Total Errors:** {total_errors_week}")
lines.append("")

# Health score trends from CSV
if os.path.exists(stats_csv):
    try:
        repo_scores = defaultdict(list)
        week_start = (today - timedelta(days=6)).strftime('%Y-%m-%d')
        with open(stats_csv, 'r', encoding='utf-8') as f:
            reader = csv.reader(f)
            header = next(reader, None)
            for row in reader:
                if len(row) >= 6 and row[0] >= week_start:
                    try:
                        score = int(row[5]) if row[5] != '-' else None
                        if score is not None:
                            repo_scores[row[1]].append((row[0], score))
                    except ValueError:
                        pass

        if repo_scores:
            lines.append("## Health Score Trends")
            lines.append("")
            lines.append("| Repository | Start | End | Δ | Trend |")
            lines.append("| :--- | :---: | :---: | :---: | :--- |")
            for repo, scores in sorted(repo_scores.items()):
                if len(scores) >= 2:
                    first = scores[0][1]
                    last = scores[-1][1]
                    delta = last - first
                    if delta > 0:
                        trend = f"📈 +{delta}"
                    elif delta < 0:
                        trend = f"📉 {delta}"
                    else:
                        trend = "➡️ stable"
                    lines.append(f"| {repo} | {first} | {last} | {delta:+d} | {trend} |")
                elif len(scores) == 1:
                    lines.append(f"| {repo} | {scores[0][1]} | {scores[0][1]} | 0 | ➡️ new |")
            lines.append("")
    except Exception:
        pass

# Top issues of the week
lines.append("## Daily Reports")
lines.append("")
for ds in sorted(daily_summaries):
    lines.append(f"- [{ds}](./{ds}.md)")
lines.append("")

os.makedirs(os.path.dirname(weekly_path), exist_ok=True)
with open(weekly_path, 'w', encoding='utf-8') as f:
    f.write("\n".join(lines) + "\n")
PYEOF
  fi

  # Commit weekly report
  local orig_pwd
  orig_pwd="$(pwd)"
  cd "$script_dir" || return 0
  commit_and_push "docs: generate weekly digest for $(date -u +%Y)-W$(date -u +%V)" || true
  cd "$orig_pwd" || true

  # Send webhook with weekly summary
  if [[ -f "$weekly_path" ]]; then
    local digest_msg
    digest_msg="📊 [Weekly Digest] Week $(date -u +%V) summary: Repos maintained across $(date -u +%V) days. Check reports/weekly/ for details."
    send_webhook "$digest_msg" || true
  fi

  log_summary "daily-bot" "reporting" "weekly_digest" "Generated weekly digest for $(date -u +%Y)-W$(date -u +%V)"
}

# Helper: Generate cross-repo SVG dashboard
_reporting_generate_dashboard() {
  local today="$1"
  local script_dir="$2"
  local work_dir="$3"
  local csv_path="${work_dir}/repo-stats-today.csv"
  
  if [[ ! -f "$csv_path" ]]; then
    return 0
  fi
  
  log_info "Generating cross-repo SVG dashboard..."
  local report_dir="${script_dir}/reports"
  mkdir -p "$report_dir"
  local dash_path="${report_dir}/dashboard.svg"
  
  if command -v python3 &>/dev/null; then
    python3 - "$today" "$csv_path" "$dash_path" << 'PYEOF' || true
import sys, csv, os
from datetime import datetime

today = sys.argv[1]
csv_path = sys.argv[2]
dash_path = sys.argv[3]

repos = []
try:
    with open(csv_path, 'r', encoding='utf-8') as f:
        reader = csv.reader(f)
        for row in reader:
            if len(row) >= 6:
                try:
                    health = int(row[5]) if row[5] != '-' else 0
                    repos.append({
                        'name': row[1],
                        'stars': int(row[2]),
                        'health': health
                    })
                except ValueError:
                    pass
except Exception:
    pass

repos.sort(key=lambda x: x['health'], reverse=True)

# Deep space palette
bg_color = "#0d1117"
text_color = "#c9d1d9"
accent_violet = "#8a2be2"
accent_cyan = "#00ffff"
accent_magenta = "#ff00ff"
accent_gold = "#ffd700"
good_color = "#2ea043"
warn_color = "#d29922"
bad_color = "#f85149"

svg_width = 800
row_height = 40
header_height = 80
margin = 20
svg_height = header_height + (len(repos) * row_height) + margin * 2

svg = [
    f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {svg_width} {svg_height}" width="{svg_width}" height="{svg_height}">',
    f'  <rect width="100%" height="100%" fill="{bg_color}" rx="8"/>',
    '  <style>',
    '    .title { font: bold 24px sans-serif; fill: ' + accent_cyan + '; }',
    '    .subtitle { font: 14px sans-serif; fill: ' + accent_violet + '; }',
    '    .repo-name { font: bold 16px sans-serif; fill: ' + text_color + '; }',
    '    .score-text { font: bold 14px sans-serif; }',
    '    .bar-bg { fill: #21262d; rx: 4; }',
    '    .grid-line { stroke: #30363d; stroke-width: 1; stroke-dasharray: 4; }',
    '  </style>',
    f'  <text x="{margin}" y="{margin + 24}" class="title">Daily-Bot Health Dashboard</text>',
    f'  <text x="{margin}" y="{margin + 44}" class="subtitle">Generated on {today} • {len(repos)} repositories</text>',
]

y_offset = header_height
max_name_width = 250
bar_width_max = svg_width - max_name_width - (margin * 3) - 50

for repo in repos:
    name = repo['name']
    if len(name) > 30:
        name = name[:27] + "..."
    score = repo['health']
    
    if score >= 90:
        bar_color = good_color
    elif score >= 70:
        bar_color = accent_gold
    elif score >= 50:
        bar_color = warn_color
    else:
        bar_color = bad_color

    bar_len = (score / 100) * bar_width_max
    
    svg.extend([
        f'  <line x1="{margin}" y1="{y_offset}" x2="{svg_width - margin}" y2="{y_offset}" class="grid-line"/>',
        f'  <text x="{margin}" y="{y_offset + 25}" class="repo-name">{name}</text>',
        f'  <rect x="{margin + max_name_width}" y="{y_offset + 12}" width="{bar_width_max}" height="16" class="bar-bg"/>',
        f'  <rect x="{margin + max_name_width}" y="{y_offset + 12}" width="{max(bar_len, 2)}" height="16" fill="{bar_color}" rx="4"/>',
        f'  <text x="{margin + max_name_width + bar_width_max + 10}" y="{y_offset + 25}" class="score-text" fill="{bar_color}">{score}%</text>'
    ])
    y_offset += row_height

svg.append('</svg>')

os.makedirs(os.path.dirname(dash_path), exist_ok=True)
with open(dash_path, 'w', encoding='utf-8') as f:
    f.write("\n".join(svg) + "\n")
PYEOF
  fi

  local orig_pwd
  orig_pwd="$(pwd)"
  cd "$script_dir" || return 0
  commit_and_push "docs: update cross-repo SVG dashboard" || true
  cd "$orig_pwd" || true
  log_summary "daily-bot" "reporting" "dashboard_svg" "Generated cross-repo dashboard at reports/dashboard.svg"
}

