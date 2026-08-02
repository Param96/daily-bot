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

        if commit_and_push "fix: automated npm audit fixes"; then
          log_info "Committed and pushed npm audit fixes for ${repo_name}"
          log_summary "$repo_name" "security" "npm_audit" "Applied automated npm audit fixes"
        else
          log_info "No changes resulted from npm audit fix for ${repo_name}"
          log_summary "$repo_name" "security" "npm_audit" "No changes from npm audit fix"
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

  cd "$orig_pwd" || true
}
