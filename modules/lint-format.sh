#!/usr/bin/env bash
# ------------------------------------------------------------------
# modules/lint-format.sh — Linting and formatting module for daily-bot
#
# Runs ESLint, Prettier, and Black auto-fixers based on repo files
# and per-repo configuration flags.
#
# Entry point: run_lint_format <repo_name> <repo_dir>
# ------------------------------------------------------------------

_has_eslint_config() {
  local pattern f
  shopt -s nullglob
  for pattern in ".eslintrc*" "eslint.config.js" "eslint.config.mjs" "eslint.config.cjs"; do
    for f in $pattern; do
      if [[ -e "$f" ]]; then
        shopt -u nullglob
        return 0
      fi
    done
  done
  shopt -u nullglob
  return 1
}

_has_prettier_config() {
  local pattern f
  shopt -s nullglob
  for pattern in ".prettierrc*" "prettier.config.js" "prettier.config.mjs"; do
    for f in $pattern; do
      if [[ -e "$f" ]]; then
        shopt -u nullglob
        return 0
      fi
    done
  done
  shopt -u nullglob
  return 1
}

run_lint_format() {
  local repo_name="$1"
  local repo_dir="$2"

  if ! module_enabled "lint"; then
    log_info "Module 'lint' is disabled for ${repo_name}"
    return 0
  fi

  if [[ ! -d "$repo_dir" ]]; then
    log_error "Repository directory not found: ${repo_dir}"
    return 1
  fi

  pushd "$repo_dir" >/dev/null || return 1

  # 1. ESLint
  if [[ "$(cfg_get "lint.eslint")" == "true" ]]; then
    if [[ -f package.json ]] && _has_eslint_config; then
      if command -v npx &>/dev/null; then
        log_info "Running ESLint auto-fix for ${repo_name}..."
        npx --yes eslint . --fix --quiet || true
      else
        log_warn "npx not found; skipping ESLint for ${repo_name}"
      fi
    fi
  fi

  # 2. Prettier
  if [[ "$(cfg_get "lint.prettier")" == "true" ]]; then
    if [[ -f package.json ]] && _has_prettier_config; then
      if command -v npx &>/dev/null; then
        log_info "Running Prettier auto-fix for ${repo_name}..."
        npx --yes prettier --write . --loglevel error || true
      else
        log_warn "npx not found; skipping Prettier for ${repo_name}"
      fi
    fi
  fi

  # 3. Black
  if [[ "$(cfg_get "lint.black")" == "true" ]]; then
    if find . -maxdepth 2 -name '*.py' | grep -q .; then
      if command -v black &>/dev/null; then
        log_info "Running Black auto-fix for ${repo_name}..."
        black . --quiet || true
      else
        log_warn "black not found; skipping Black for ${repo_name}"
      fi
    fi
  fi

  # Commit & push any changes, log to summary (safe — formatting only)
  if commit_and_push_safe "fix: automated lint/format fixes"; then
    log_info "Automated lint/format fixes pushed for ${repo_name}"
    log_summary "$repo_name" "lint-format" "fixed" "Applied automated lint/format fixes"
  else
    log_info "No lint/format changes required for ${repo_name}"
    log_summary "$repo_name" "lint-format" "clean" "No lint/format fixes required"
  fi

  popd >/dev/null || true
  return 0
}
