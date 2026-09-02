#!/usr/bin/env bash
# ------------------------------------------------------------------
# modules/dependency-update.sh — Dependency update module for daily-bot
#
# Checks for outdated (not just vulnerable) dependencies and opens PRs.
# Supports Node.js (npm outdated/update) and Python (PyPI package check).
# Sourced after lib/utils.sh is loaded by the orchestrator.
#
# Exposes entry-point function:
#   run_dependency_update(repo_name, repo_dir)
# ------------------------------------------------------------------

_get_python() {
  local py
  for py in /usr/bin/python3 /opt/homebrew/bin/python3 /usr/local/bin/python3 python3; do
    if command -v "$py" &>/dev/null && "$py" -c "import sys, json" &>/dev/null; then
      echo "$py"
      return 0
    fi
  done
  echo "python3"
}

run_dependency_update() {
  local repo_name="$1"
  local repo_dir="$2"

  if ! module_enabled "dependencies"; then
    log_info "Module 'dependencies' is disabled for ${repo_name}"
    return 0
  fi

  log_info "Running dependency-update module for repo: ${repo_name}"

  local orig_pwd
  orig_pwd="$(pwd)"

  if [[ -n "$repo_dir" && -d "$repo_dir" ]]; then
    cd "$repo_dir" || return 0
  fi

  local py_cmd
  py_cmd="$(_get_python)"

  # 1. Node.js dependencies
  if [[ "$(cfg_get "dependencies.npm_update")" == "true" ]]; then
    if [[ -f "package.json" && -f "package-lock.json" ]]; then
      if command -v npm &>/dev/null; then
        log_info "Checking Node.js dependencies for ${repo_name}..."
        local npm_outdated_json npm_pr_body
        npm_outdated_json=$(npm outdated --json 2>/dev/null || true)

        if [[ -n "$npm_outdated_json" && "$npm_outdated_json" != "{}" ]]; then
          npm_pr_body=$("$py_cmd" -c '
import sys, json

content = sys.stdin.read().strip()
if not content:
    sys.exit(1)

try:
    data = json.loads(content)
except Exception:
    sys.exit(1)

if not isinstance(data, dict) or not data:
    sys.exit(1)

lines = [
    "## Outdated NPM Dependencies",
    "",
    "The following NPM dependencies were updated automatically by daily-bot:",
    "",
    "| Package | Current | Wanted | Latest |",
    "| --- | --- | --- | --- |"
]

count = 0
for pkg in sorted(data.keys()):
    details = data[pkg]
    if isinstance(details, dict):
        cur = details.get("current", "N/A")
        wanted = details.get("wanted", "N/A")
        latest = details.get("latest", "N/A")
        lines.append(f"| `{pkg}` | `{cur}` | `{wanted}` | `{latest}` |")
        count += 1

if count > 0:
    print("\n".join(lines))
    sys.exit(0)
else:
    sys.exit(1)
' <<< "$npm_outdated_json" 2>/dev/null || true)

          if [[ -n "$npm_pr_body" ]]; then
            log_info "Updating npm dependencies for ${repo_name}..."
            npm update 2>/dev/null || true
            if propose_as_pr "$repo_name" "deps-npm" "fix: update outdated npm dependencies" "$npm_pr_body"; then
              log_info "Proposed PR for npm dependency updates on ${repo_name}"
              log_summary "$repo_name" "dependency-update" "npm" "Proposed PR for outdated npm dependencies"
            else
              log_info "No npm dependency changes to propose for ${repo_name}"
              log_summary "$repo_name" "dependency-update" "npm_clean" "No npm dependency changes to propose"
            fi
          else
            log_info "All npm dependencies are up to date for ${repo_name}"
            log_summary "$repo_name" "dependency-update" "npm_clean" "All npm dependencies up to date"
          fi
        else
          log_info "All npm dependencies are up to date for ${repo_name}"
          log_summary "$repo_name" "dependency-update" "npm_clean" "All npm dependencies up to date"
        fi
      else
        log_warn "npm command not found; skipping npm dependency update for ${repo_name}"
      fi
    fi
  fi

  # 2. Python dependencies
  if [[ "$(cfg_get "dependencies.pip_update")" == "true" ]]; then
    if [[ -f "requirements.txt" ]]; then
      if [[ -n "$py_cmd" ]]; then
        log_info "Checking Python dependencies for ${repo_name}..."
        local pip_pr_body
        pip_pr_body=$("$py_cmd" -c '
import sys, os, re, json, ssl
import urllib.request, urllib.error

req_file = "requirements.txt"
if not os.path.exists(req_file):
    sys.exit(1)

try:
    with open(req_file, "r", encoding="utf-8", errors="replace") as f:
        lines = f.readlines()
except Exception:
    sys.exit(1)

pinned_pattern = re.compile(r"^(\s*)([A-Za-z0-9_.\-]+)(\s*==\s*)([A-Za-z0-9_.\-+]+)(.*)$")

outdated = []
new_lines = []
checked_count = 0

ctx = ssl.create_default_context()
try:
    import certifi
    ctx.load_verify_locations(certifi.where())
except Exception:
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE

for line in lines:
    match = pinned_pattern.match(line)
    if match and checked_count < 20:
        checked_count += 1
        indent, pkg_name, eq, current_version, rest = match.groups()
        latest_version = None
        url = f"https://pypi.org/pypi/{pkg_name}/json"
        req = urllib.request.Request(url, headers={"User-Agent": "daily-bot/1.0"})
        try:
            with urllib.request.urlopen(req, timeout=5, context=ctx) as response:
                if response.status == 200:
                    data = json.loads(response.read().decode("utf-8"))
                    latest_version = data.get("info", {}).get("version")
        except Exception:
            try:
                unverified_ctx = ssl._create_unverified_context()
                with urllib.request.urlopen(req, timeout=5, context=unverified_ctx) as response:
                    if response.status == 200:
                        data = json.loads(response.read().decode("utf-8"))
                        latest_version = data.get("info", {}).get("version")
            except Exception:
                latest_version = None

        if latest_version and latest_version != current_version:
            outdated.append({
                "package": pkg_name,
                "current": current_version,
                "latest": latest_version
            })
            nl = "\n" if line.endswith("\n") and not rest.endswith("\n") else ""
            new_lines.append(f"{indent}{pkg_name}{eq}{latest_version}{rest}{nl}")
        else:
            new_lines.append(line)
    else:
        new_lines.append(line)

if outdated:
    try:
        with open(req_file, "w", encoding="utf-8") as f:
            f.writelines(new_lines)
    except Exception:
        sys.exit(1)

    table_lines = [
        "## Outdated Python Dependencies",
        "",
        "The following Python dependencies were updated automatically by daily-bot:",
        "",
        "| Package | Current | Latest |",
        "| --- | --- | --- |"
    ]
    for item in outdated:
        pkg = item["package"]
        cur = item["current"]
        latest = item["latest"]
        table_lines.append(f"| `{pkg}` | `{cur}` | `{latest}` |")

    print("\n".join(table_lines))
    sys.exit(0)
else:
    sys.exit(1)
' 2>/dev/null || true)

        if [[ -n "$pip_pr_body" ]]; then
          log_info "Updating pip dependencies for ${repo_name}..."
          if propose_as_pr "$repo_name" "deps-pip" "fix: update outdated pip dependencies" "$pip_pr_body"; then
            log_info "Proposed PR for pip dependency updates on ${repo_name}"
            log_summary "$repo_name" "dependency-update" "pip" "Proposed PR for outdated pip dependencies"
          else
            log_info "No pip dependency changes to propose for ${repo_name}"
            log_summary "$repo_name" "dependency-update" "pip_clean" "No pip dependency changes to propose"
          fi
        else
          log_info "All pip dependencies are up to date for ${repo_name}"
          log_summary "$repo_name" "dependency-update" "pip_clean" "All pip dependencies up to date"
        fi
      else
        log_warn "python3 command not found; skipping pip dependency update for ${repo_name}"
      fi
    fi
  fi

  # 3. Auto-merge Dependabot PRs
  if [[ "$(cfg_get "dependencies.auto_merge_dependabot")" == "true" ]]; then
    if command -v gh &>/dev/null; then
      log_info "Checking for open dependabot PRs..."
      local pr_list
      pr_list=$(gh pr list --state open --author "app/dependabot" --json number --jq '.[].number' 2>/dev/null || echo "")
      for pr_num in $pr_list; do
        log_info "Checking CI status for PR #$pr_num..."
        local ci_status
        ci_status=$(gh pr checks "$pr_num" --json state --jq 'if length == 0 then "fail" elif all(.state == "SUCCESS") then "pass" else "fail" end' 2>/dev/null || echo "fail")
        if [[ "$ci_status" == "pass" ]]; then
          log_info "CI passed for PR #$pr_num. Auto-merging..."
          if gh pr merge "$pr_num" --auto --squash 2>/dev/null; then
            log_summary "$repo_name" "dependency-update" "auto-merge" "Auto-merged dependabot PR #$pr_num"
          else
            log_warn "Failed to auto-merge PR #$pr_num"
            log_summary "$repo_name" "dependency-update" "error" "Failed to auto-merge dependabot PR #$pr_num"
          fi
        else
          log_info "CI not fully passing for PR #$pr_num. Skipping auto-merge."
        fi
      done
    fi
  fi

  cd "$orig_pwd" || true
  return 0
}
