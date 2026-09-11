#!/usr/bin/env bash
# ------------------------------------------------------------------
# modules/rollback.sh — Rollback module for daily-bot
#
# Runs at the START of each per-repo pipeline (before lint/format).
# Detects if the bot's previous commit broke CI and automatically
# reverts it.
#
# Entry point: run_rollback <repo_name> <repo_dir>
# Gated by: rollback.enabled in configuration
# ------------------------------------------------------------------

run_rollback() {
  local repo_name="$1"
  local repo_dir="$2"

  # 1. Check if module is enabled
  if ! module_enabled "rollback"; then
    log_info "Module 'rollback' is disabled for ${repo_name}"
    return 0
  fi

  if [[ -z "$repo_dir" || ! -d "$repo_dir" ]]; then
    log_error "rollback module: Invalid repo directory '${repo_dir}'"
    return 1
  fi

  local orig_dir
  orig_dir="$(pwd)"

  # 2. cd into repo_dir
  cd "$repo_dir" || return 1

  # 3. Get the last commit on the current branch: git log -1 --format='%H %ae %s'
  local last_commit
  last_commit=$(git log -1 --format='%H %ae %s' 2>/dev/null || true)

  if [[ -z "$last_commit" ]]; then
    log_info "No commits found in ${repo_name}; skipping rollback check"
    cd "$orig_dir" || true
    return 0
  fi

  local commit_sha author_email commit_msg rest
  commit_sha="${last_commit%% *}"
  rest="${last_commit#* }"
  author_email="${rest%% *}"
  commit_msg="${rest#* }"

  # 4. Check if the last commit was made by the bot:
  #    author email == 'paramppatel100@gmail.com' AND message starts with 'fix:' or 'chore: daily'
  if [[ "$author_email" == "paramppatel100@gmail.com" ]] && \
     [[ "$commit_msg" == fix:* || "$commit_msg" == chore:\ daily* ]]; then

    # 5. If it IS a bot commit:
    # Call check_ci_status "$repo_name" "$commit_sha" (from utils.sh)
    local ci_status
    ci_status=$(check_ci_status "$repo_name" "$commit_sha")

    case "$ci_status" in
      "failure")
        # If CI status is 'failure': call rollback_commit "$repo_name" "$repo_dir" "$commit_sha"
        log_warn "CI failed for commit ${commit_sha:0:8} on ${repo_name}. Rolling back..."
        rollback_commit "$repo_name" "$repo_dir" "$commit_sha"
        send_webhook_critical "CI failed on ${repo_name} for bot commit ${commit_sha:0:8}. Commit rolled back automatically."
        ;;
      "pending")
        # If CI status is 'pending': log_info 'CI still running, skipping rollback check'
        log_info "CI still running, skipping rollback check"
        ;;
      "success"|"none")
        # If CI status is 'success' or 'none': log_info and do nothing
        log_info "CI status for commit ${commit_sha:0:8} on ${repo_name} is '${ci_status}'; no rollback needed"
        ;;
      *)
        log_info "CI status for commit ${commit_sha:0:8} on ${repo_name} is '${ci_status}'; no rollback needed"
        ;;
    esac
  else
    # 6. If it's NOT a bot commit: do nothing
    :
  fi

  # 7. cd back to original dir
  cd "$orig_dir" || true
  return 0
}
