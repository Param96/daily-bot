#!/usr/bin/env bash
# ------------------------------------------------------------------
# modules/repo-hygiene.sh — Repository hygiene module for daily-bot
#
# Handles repository hygiene:
#  1. Deletes merged or stale remote branches (hygiene.stale_branches)
#  2. Labels stale issues and PRs via gh CLI (hygiene.stale_issues)
#  3. Verifies presence of a README file (hygiene.readme_check)
#  4. Checks for broken links in Markdown files via lychee (hygiene.broken_links)
# ------------------------------------------------------------------

run_repo_hygiene() {
  local repo_name="$1"
  local repo_dir="$2"

  if ! module_enabled "hygiene"; then
    return 0
  fi

  log_info "Running repo-hygiene module for ${repo_name}..."

  local orig_dir="$PWD"
  if [[ -d "$repo_dir" ]]; then
    cd "$repo_dir" || return 1
  fi

  export GH_TOKEN="${GH_TOKEN:-}"

  # ----------------------------------------------------------------
  # Feature 1: hygiene.stale_branches
  # ----------------------------------------------------------------
  if [[ "$(cfg_get "hygiene.stale_branches")" == "true" ]]; then
    log_info "Checking stale and merged remote branches..."

    # Fetch remote branches and update origin/HEAD if needed
    git fetch --prune origin &>/dev/null || true
    git remote set-head origin --auto &>/dev/null || true

    local default_ref="origin/HEAD"
    if ! git rev-parse --verify origin/HEAD &>/dev/null; then
      if git rev-parse --verify origin/main &>/dev/null; then
        default_ref="origin/main"
      elif git rev-parse --verify origin/master &>/dev/null; then
        default_ref="origin/master"
      fi
    fi

    local merged_branches
    merged_branches=$(git branch -r --merged "$default_ref" 2>/dev/null | sed 's/^[ *]*//' | sed 's|^origin/||' || true)

    local all_remote_branches
    all_remote_branches=$(git branch -r 2>/dev/null | sed 's/^[ *]*//' | grep -v -- '->' | sed 's|^origin/||' || true)

    local stale_branch_days
    stale_branch_days=$(cfg_get "hygiene.stale_branch_days")
    if [[ -z "$stale_branch_days" || "$stale_branch_days" == "true" || ! "$stale_branch_days" =~ ^[0-9]+$ ]]; then
      stale_branch_days=90
    fi

    local now_sec
    now_sec=$(date +%s)
    local cutoff_sec=$(( stale_branch_days * 86400 ))

    local branch
    for branch in $all_remote_branches; do
      [[ -z "$branch" ]] && continue

      # Exclude default/protected branches
      case "$branch" in
        main|master|develop|HEAD)
          continue
          ;;
      esac

      local should_delete=false
      local delete_reason=""

      # Check if branch is fully merged into default branch
      if echo "$merged_branches" | grep -qxF "$branch"; then
        should_delete=true
        delete_reason="merged into default branch"
      else
        # Unmerged branch: check last commit date
        local commit_sec
        commit_sec=$(git log -1 --format=%ct "origin/${branch}" 2>/dev/null || echo "0")
        if [[ "$commit_sec" -gt 0 ]]; then
          local age_sec=$(( now_sec - commit_sec ))
          if (( age_sec >= cutoff_sec )); then
            local age_days=$(( age_sec / 86400 ))
            should_delete=true
            delete_reason="unmerged and stale (last commit ${age_days} days ago, threshold: ${stale_branch_days} days)"
          fi
        fi
      fi

      if [[ "$should_delete" == "true" ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
          log_info "[dry-run] Would delete remote branch '${branch}' (${delete_reason})"
          log_summary "$repo_name" "hygiene" "stale_branch_dry_run" "Would delete branch ${branch} (${delete_reason})"
        else
          if git push origin --delete "$branch" &>/dev/null; then
            log_info "Deleted remote branch '${branch}' (${delete_reason})"
            log_summary "$repo_name" "hygiene" "delete_branch" "Deleted branch ${branch} (${delete_reason})"
          else
            log_warn "Failed to delete remote branch '${branch}'"
            log_summary "$repo_name" "hygiene" "delete_branch_failed" "Failed to delete branch ${branch}"
          fi
        fi
      fi
    done
  fi

  # ----------------------------------------------------------------
  # Feature 2: hygiene.stale_issues
  # ----------------------------------------------------------------
  if [[ "$(cfg_get "hygiene.stale_issues")" == "true" ]]; then
    if command -v gh &>/dev/null; then
      log_info "Checking stale issues and PRs with gh CLI..."
      local stale_issue_days
      stale_issue_days=$(cfg_get "hygiene.stale_issue_days")
      if [[ -z "$stale_issue_days" || "$stale_issue_days" == "true" || ! "$stale_issue_days" =~ ^[0-9]+$ ]]; then
        stale_issue_days=30
      fi

      local py_bin="python3"
      if command -v /usr/bin/python3 &>/dev/null; then
        py_bin="/usr/bin/python3"
      fi

      local filter_py='
import sys, json, datetime

try:
    data = json.loads(sys.argv[1])
    stale_days = float(sys.argv[2])
    now = datetime.datetime.now(datetime.timezone.utc)
    for item in data:
        updated_str = item.get("updatedAt", "").replace("Z", "+00:00")
        if not updated_str:
            continue
        try:
            updated_dt = datetime.datetime.fromisoformat(updated_str)
        except Exception:
            continue
        age_days = (now - updated_dt).total_seconds() / 86400.0
        if age_days >= stale_days:
            num = item.get("number")
            title = item.get("title", "").replace("\t", " ").replace("\n", " ")
            print(f"{num}\t{title}")
except Exception:
    pass
'

      # Open Issues
      local issues_json
      issues_json=$(gh issue list --state open --json number,title,updatedAt --limit 100 2>/dev/null || true)
      if [[ -n "$issues_json" && "$issues_json" != "[]" ]]; then
        local stale_issues=""
        if command -v "$py_bin" &>/dev/null; then
          stale_issues=$("$py_bin" -c "$filter_py" "$issues_json" "$stale_issue_days")
        fi

        if [[ -n "$stale_issues" ]]; then
          while IFS=$'\t' read -r num title; do
            [[ -z "$num" ]] && continue
            if [[ "$DRY_RUN" == "true" ]]; then
              log_info "[dry-run] Would add 'stale' label to issue #${num} (${title})"
              log_summary "$repo_name" "hygiene" "stale_issue_dry_run" "Would label issue #${num} as stale: ${title}"
            else
              if gh issue edit "$num" --add-label "stale" &>/dev/null; then
                log_info "Added 'stale' label to issue #${num} (${title})"
                log_summary "$repo_name" "hygiene" "stale_issue" "Labeled issue #${num} as stale: ${title}"
              else
                log_warn "Failed to add 'stale' label to issue #${num}"
                log_summary "$repo_name" "hygiene" "stale_issue_failed" "Failed to label issue #${num} as stale"
              fi
            fi
          done <<< "$stale_issues"
        fi
      fi

      # Open PRs
      local prs_json
      prs_json=$(gh pr list --state open --json number,title,updatedAt --limit 100 2>/dev/null || true)
      if [[ -n "$prs_json" && "$prs_json" != "[]" ]]; then
        local stale_prs=""
        if command -v "$py_bin" &>/dev/null; then
          stale_prs=$("$py_bin" -c "$filter_py" "$prs_json" "$stale_issue_days")
        fi

        if [[ -n "$stale_prs" ]]; then
          while IFS=$'\t' read -r num title; do
            [[ -z "$num" ]] && continue
            if [[ "$DRY_RUN" == "true" ]]; then
              log_info "[dry-run] Would add 'stale' label to PR #${num} (${title})"
              log_summary "$repo_name" "hygiene" "stale_pr_dry_run" "Would label PR #${num} as stale: ${title}"
            else
              if gh pr edit "$num" --add-label "stale" &>/dev/null; then
                log_info "Added 'stale' label to PR #${num} (${title})"
                log_summary "$repo_name" "hygiene" "stale_pr" "Labeled PR #${num} as stale: ${title}"
              elif gh issue edit "$num" --add-label "stale" &>/dev/null; then
                log_info "Added 'stale' label to PR #${num} via issue edit (${title})"
                log_summary "$repo_name" "hygiene" "stale_pr" "Labeled PR #${num} as stale: ${title}"
              else
                log_warn "Failed to add 'stale' label to PR #${num}"
                log_summary "$repo_name" "hygiene" "stale_pr_failed" "Failed to label PR #${num} as stale"
              fi
            fi
          done <<< "$stale_prs"
        fi
      fi
    else
      log_warn "gh CLI not found, skipping stale_issues check"
    fi
  fi

  # ----------------------------------------------------------------
  # Feature 3: hygiene.readme_check
  # ----------------------------------------------------------------
  if [[ "$(cfg_get "hygiene.readme_check")" == "true" ]]; then
    log_info "Checking for README file..."
    local has_readme=false
    if [[ -f "README.md" || -f "README" || -f "readme.md" || -f "readme" || -f "README.rst" || -f "README.txt" ]]; then
      has_readme=true
    fi

    if [[ "$has_readme" == "false" ]]; then
      log_warn "Repository '${repo_name}' is missing a README file"
      log_summary "$repo_name" "hygiene" "readme_check" "Repository missing README.md or README"
    else
      log_info "README file present in '${repo_name}'"
    fi
  fi

  # ----------------------------------------------------------------
  # Feature 4: hygiene.broken_links
  # ----------------------------------------------------------------
  if [[ "$(cfg_get "hygiene.broken_links")" == "true" ]]; then
    if command -v lychee &>/dev/null; then
      log_info "Checking broken links with lychee..."
      local lychee_out
      local lychee_exit=0
      lychee_out=$(lychee --no-progress '**/*.md' 2>&1) || lychee_exit=$?

      if [[ $lychee_exit -ne 0 ]]; then
        local broken_summary
        broken_summary=$(echo "$lychee_out" | grep -E "✗|\[[0-9]{3}\]|Error:" | head -n 10 | tr '\n' ' | ')
        if [[ -z "$broken_summary" ]]; then
          broken_summary=$(echo "$lychee_out" | tail -n 5 | tr '\n' ' | ')
        fi
        log_warn "Broken links found in '${repo_name}': ${broken_summary}"
        log_summary "$repo_name" "hygiene" "broken_links" "Broken links detected: ${broken_summary}"
      else
        log_info "No broken links found in '${repo_name}'"
      fi
    else
      log_info "lychee is not installed, skipping broken links check"
    fi
  fi

  cd "$orig_dir" || true
  return 0
}
