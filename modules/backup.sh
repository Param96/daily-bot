#!/usr/bin/env bash
# ------------------------------------------------------------------
# modules/backup.sh — Automated backup module for daily-bot
# ------------------------------------------------------------------

run_backup() {
  local repo_name="$1"
  local repo_dir="$2"

  if ! module_enabled "backup"; then
    return 0
  fi

  local dest
  dest=$(cfg_get "backup.destination")
  if [[ -z "$dest" ]]; then
    dest="${HOME}/backups/daily-bot"
  fi
  # resolve tilde if needed
  dest="${dest/#\~/$HOME}"

  log_info "Running backup for $repo_name to $dest..."
  
  local today
  today=$(date -u +'%Y-%m-%d')
  local archive_name="${repo_name}-${today}.tar.gz"
  local tmp_archive="${WORKDIR}/${archive_name}"

  # Create tar inside the repo, excluding .git if desired, but for backups we usually want .git
  # We will tar the whole directory
  local orig_pwd
  orig_pwd="$(pwd)"
  cd "${repo_dir}/.." || return 1
  
  local base_name
  base_name=$(basename "$repo_dir")
  
  if ! tar -czf "$tmp_archive" "$base_name" 2>/dev/null; then
    log_error "backup: failed to create tar archive for $repo_name"
    cd "$orig_pwd" || return 1
    return 1
  fi
  cd "$orig_pwd" || return 1

  # Check if dest is s3://
  if [[ "$dest" == s3://* ]]; then
    if command -v aws &>/dev/null; then
      if aws s3 cp "$tmp_archive" "${dest}/${archive_name}" --quiet; then
        log_summary "$repo_name" "backup" "success" "Uploaded backup to ${dest}/${archive_name}"
      else
        log_error "backup: S3 upload failed for $repo_name"
        log_summary "$repo_name" "backup" "error" "S3 upload failed"
      fi
    else
      log_warn "backup: aws cli not installed, cannot upload to S3"
      log_summary "$repo_name" "backup" "warning" "aws cli not installed"
    fi
  else
    # Local backup
    mkdir -p "$dest"
    if mv "$tmp_archive" "${dest}/${archive_name}"; then
      log_summary "$repo_name" "backup" "success" "Saved backup to ${dest}/${archive_name}"
    else
      log_error "backup: failed to move archive to $dest"
      log_summary "$repo_name" "backup" "error" "Failed to save local backup"
    fi
  fi
}
