#!/usr/bin/env bash
# ------------------------------------------------------------------
# modules/docs.sh — Documentation auto-deploy module for daily-bot
# ------------------------------------------------------------------

run_docs() {
  local repo_name="$1"
  local repo_dir="$2"

  if ! module_enabled "docs"; then
    return 0
  fi

  log_info "Running documentation auto-deploy for $repo_name..."

  local orig_pwd
  orig_pwd="$(pwd)"
  cd "$repo_dir" || return 1

  local docs_built=false
  local build_dir="site"

  # 1. Check for MkDocs
  if [[ -f "mkdocs.yml" ]]; then
    if command -v mkdocs &>/dev/null; then
      log_info "Found mkdocs.yml, building docs..."
      if mkdocs build; then
        docs_built=true
        build_dir="site"
      else
        log_error "Failed to build mkdocs for $repo_name"
        log_summary "$repo_name" "docs" "error" "mkdocs build failed"
      fi
    else
      log_warn "mkdocs.yml found but mkdocs command not installed"
    fi
  # 2. Check for docs/Makefile (Sphinx)
  elif [[ -f "docs/Makefile" ]]; then
    if command -v sphinx-build &>/dev/null || command -v make &>/dev/null; then
      log_info "Found Sphinx docs/Makefile, building docs..."
      cd docs || return 1
      if make html; then
        docs_built=true
        build_dir="docs/_build/html"
      else
        log_error "Failed to build sphinx docs for $repo_name"
        log_summary "$repo_name" "docs" "error" "sphinx make html failed"
      fi
      cd .. || return 1
    fi
  fi

  # Deploy to gh-pages if requested and built successfully
  if [[ "$docs_built" == "true" && "$(cfg_get "docs.deploy_gh_pages")" == "true" ]]; then
    if [[ -d "$build_dir" ]]; then
      log_info "Deploying $build_dir to gh-pages branch..."
      
      # Using a quick git commit-tree approach to push a directory to a branch
      # without checking it out
      local tree_sha
      # create a temp index
      export GIT_INDEX_FILE="${repo_dir}/.git/docs_index"
      git --work-tree="$build_dir" add .
      tree_sha=$(git write-tree)
      local commit_sha
      commit_sha=$(echo "Auto-deploy docs for $(date -u +'%Y-%m-%d')" | git commit-tree "$tree_sha")
      
      if git push origin "${commit_sha}:refs/heads/gh-pages" --force; then
        log_summary "$repo_name" "docs" "success" "Deployed docs to gh-pages"
      else
        log_error "Failed to push gh-pages for $repo_name"
        log_summary "$repo_name" "docs" "error" "Failed to push gh-pages branch"
      fi
      rm -f "$GIT_INDEX_FILE"
      unset GIT_INDEX_FILE
    else
      log_warn "Build directory $build_dir not found after successful build"
    fi
  fi

  cd "$orig_pwd" || return 1
}
