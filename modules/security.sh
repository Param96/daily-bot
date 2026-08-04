#!/usr/bin/env bash
# ------------------------------------------------------------------
# modules/security.sh — Security and dependency health module for daily-bot
#
# Performs security audits, secret scanning, and license verification.
# Sourced after lib/utils.sh is loaded by the orchestrator.
#
# Exposes entry-point function:
#   run_security(repo_name, repo_dir)
# ------------------------------------------------------------------

run_security() {
  local repo_name="$1"
  local repo_dir="$2"

  module_enabled "security" || return 0

  log_info "Running security module for repo: ${repo_name}"

  local orig_pwd
  orig_pwd="$(pwd)"

  if [[ -n "$repo_dir" && -d "$repo_dir" ]]; then
    cd "$repo_dir" || return 0
  fi

  # 1. security.npm_audit
  if [[ "$(cfg_get "security.npm_audit")" != "false" ]]; then
    if [[ -f "package.json" && -f "package-lock.json" ]]; then
      if command -v npm &>/dev/null; then
        log_info "Running npm audit fix --force for ${repo_name}..."
        local audit_out
        audit_out=$(npm audit fix --force 2>&1) || true

        local pr_mode
        pr_mode=$(cfg_get "security.npm_audit_pr_mode")
        if [[ "$pr_mode" == "true" ]]; then
          local pr_body="## npm audit fix\n\nAutomated security fixes applied by daily-bot.\n\n### Audit Output\n\n\`\`\`\n${audit_out}\n\`\`\`"
          if propose_as_pr "$repo_name" "npm-audit-fix" "fix: automated npm audit fixes" "$pr_body"; then
            log_summary "$repo_name" "security" "npm_audit" "Proposed npm audit fixes as PR"
          else
            log_summary "$repo_name" "security" "npm_audit" "No changes from npm audit fix"
          fi
        else
          if commit_and_push "fix: automated npm audit fixes"; then
            log_info "Committed and pushed npm audit fixes for ${repo_name}"
            log_summary "$repo_name" "security" "npm_audit" "Applied automated npm audit fixes"
          else
            log_summary "$repo_name" "security" "npm_audit" "No changes from npm audit fix"
          fi
        fi
      else
        log_warn "npm command not found; skipping npm_audit for ${repo_name}"
      fi
    fi
  fi

  # 2. security.pip_audit
  if [[ "$(cfg_get "security.pip_audit")" != "false" ]]; then
    if [[ -f "requirements.txt" || -f "setup.py" || -f "pyproject.toml" ]]; then
      if command -v pip-audit &>/dev/null; then
        log_info "Running pip-audit for ${repo_name}..."
        local pip_out
        if [[ -f "requirements.txt" ]]; then
          pip_out=$(pip-audit -r requirements.txt 2>&1) || true
        else
          pip_out=$(pip-audit 2>&1) || true
        fi

        local pip_detail
        pip_detail=$(echo "$pip_out" | grep -E "No known vulnerabilities|vulnerability|vulnerabilities|Vulnerability" | tail -1)
        if [[ -z "$pip_detail" ]]; then
          pip_detail="pip-audit execution completed"
        fi
        log_summary "$repo_name" "security" "pip_audit" "$pip_detail"
      else
        log_warn "pip-audit command not found; skipping pip_audit for ${repo_name}"
      fi
    fi
  fi

  # 3. security.gitleaks
  if [[ "$(cfg_get "security.gitleaks")" != "false" ]]; then
    if command -v gitleaks &>/dev/null; then
      log_info "Running gitleaks detect for ${repo_name}..."
      local gitleaks_out gitleaks_rc=0
      gitleaks_out=$(gitleaks detect --source . --no-banner 2>&1) || gitleaks_rc=$?

      if [[ $gitleaks_rc -ne 0 ]] || echo "$gitleaks_out" | grep -qi "leak\|finding\|secret"; then
        if echo "$gitleaks_out" | grep -qi "no leaks found"; then
          log_summary "$repo_name" "security" "gitleaks" "No secrets detected"
        else
          log_warn "gitleaks detected potential secrets in ${repo_name}"
          log_summary "$repo_name" "security" "gitleaks" "WARNING: Potential secrets detected by gitleaks"
        fi
      else
        log_summary "$repo_name" "security" "gitleaks" "No secrets detected"
      fi
    else
      log_warn "gitleaks command not found; skipping gitleaks for ${repo_name}"
    fi
  fi

  # 4. security.license_check
  if [[ "$(cfg_get "security.license_check")" != "false" ]]; then
    if [[ -f "LICENSE" || -f "LICENSE.md" || -f "LICENSE.txt" || -f "license" || -f "license.md" || -f "license.txt" ]]; then
      log_summary "$repo_name" "security" "license_check" "LICENSE file present"
    else
      log_warn "No LICENSE file found in ${repo_name}"
      log_summary "$repo_name" "security" "license_check" "WARNING: No LICENSE file found"
    fi
  fi

  # 5. security.trivy — Container/filesystem vulnerability scanning
  if [[ "$(cfg_get "security.trivy")" != "false" ]]; then
    if [[ -f "Dockerfile" ]] && command -v trivy &>/dev/null; then
      log_info "Running trivy filesystem scan for ${repo_name}..."
      local trivy_out trivy_rc=0
      trivy_out=$(trivy fs --severity HIGH,CRITICAL --exit-code 1 . 2>&1) || trivy_rc=$?

      if [[ $trivy_rc -ne 0 ]]; then
        local vuln_count
        vuln_count=$(echo "$trivy_out" | grep -c 'Total:' || echo "unknown")
        log_warn "trivy found HIGH/CRITICAL vulnerabilities in ${repo_name}"
        log_summary "$repo_name" "security" "trivy" "WARNING: HIGH/CRITICAL vulnerabilities detected (${vuln_count} finding(s))"
      else
        log_summary "$repo_name" "security" "trivy" "No HIGH/CRITICAL vulnerabilities found"
      fi
    elif [[ -f "Dockerfile" ]]; then
      log_info "trivy not installed; skipping container scan for ${repo_name}"
    fi
  fi

  # 6. security.sbom — Generate Software Bill of Materials using syft
  if [[ "$(cfg_get "security.sbom")" == "true" ]]; then
    if command -v syft &>/dev/null; then
      log_info "Generating SBOM for ${repo_name}..."
      local sbom_dir="${SCRIPT_DIR}/reports/sbom"
      mkdir -p "$sbom_dir"
      local sbom_out="${sbom_dir}/${repo_name}-sbom.json"
      if syft dir:. -o cyclonedx-json > "$sbom_out" 2>/dev/null; then
        local component_count
        component_count=$(python3 -c "import json; d=json.load(open('$sbom_out')); print(len(d.get('components',[])))
" 2>/dev/null || echo "unknown")
        log_info "SBOM generated for ${repo_name}: ${component_count} components"
        log_summary "$repo_name" "security" "sbom" "SBOM generated: ${component_count} components (reports/sbom/${repo_name}-sbom.json)"
      else
        log_warn "syft SBOM generation failed for ${repo_name}"
        log_summary "$repo_name" "security" "sbom" "WARNING: SBOM generation failed"
      fi
    else
      log_info "syft not installed; skipping SBOM generation for ${repo_name}"
    fi
  fi

  # 7. security.secret_rotation — Check for stale secrets based on manifest
  if [[ "$(cfg_get "security.secret_rotation")" != "false" ]]; then
    if [[ -f "secrets-manifest.yml" ]]; then
      log_info "Checking secret rotation status for ${repo_name}..."
      local max_age
      max_age=$(cfg_get "security.max_secret_age_days")
      [[ -z "$max_age" || "$max_age" == "true" ]] && max_age=90

      local rotation_result
      rotation_result=$(python3 - "secrets-manifest.yml" "$max_age" << 'PYEOF' 2>/dev/null || true
import sys, yaml, os
from datetime import datetime, timedelta

manifest_file = sys.argv[1]
max_age = int(sys.argv[2])

try:
    with open(manifest_file, 'r') as f:
        manifest = yaml.safe_load(f) or {}
except Exception:
    print("PARSE_ERROR")
    sys.exit(0)

today = datetime.utcnow().date()
stale = []
for secret_name, last_rotated in manifest.items():
    if isinstance(last_rotated, str):
        try:
            rotated_date = datetime.strptime(last_rotated, '%Y-%m-%d').date()
        except ValueError:
            stale.append(f"{secret_name} (unparseable date: {last_rotated})")
            continue
    elif hasattr(last_rotated, 'isoformat'):
        rotated_date = last_rotated if not hasattr(last_rotated, 'date') else last_rotated.date()
    else:
        stale.append(f"{secret_name} (invalid date format)")
        continue

    age = (today - rotated_date).days
    if age > max_age:
        stale.append(f"{secret_name} (last rotated: {rotated_date}, {age} days ago)")

if stale:
    print("STALE:" + "|".join(stale))
else:
    print("OK")
PYEOF
)

      if [[ "$rotation_result" == STALE:* ]]; then
        local stale_list="${rotation_result#STALE:}"
        local stale_formatted
        stale_formatted=$(echo "$stale_list" | tr '|' ', ')
        log_warn "Stale secrets in ${repo_name}: ${stale_formatted}"
        log_summary "$repo_name" "security" "secret_rotation" "WARNING: Stale secrets need rotation: ${stale_formatted}"
        # This is a critical alert — send immediate notification
        send_webhook "🔑 CRITICAL: Secrets need rotation in ${repo_name}: ${stale_formatted}"
      elif [[ "$rotation_result" == "PARSE_ERROR" ]]; then
        log_warn "Failed to parse secrets-manifest.yml in ${repo_name}"
        log_summary "$repo_name" "security" "secret_rotation" "WARNING: secrets-manifest.yml parse error"
      elif [[ "$rotation_result" == "OK" ]]; then
        log_info "All secrets within rotation window for ${repo_name}"
        log_summary "$repo_name" "security" "secret_rotation" "All secrets within rotation window"
      fi
    fi
  fi

  cd "$orig_pwd" || true
}
