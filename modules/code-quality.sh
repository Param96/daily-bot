#!/usr/bin/env bash
# ------------------------------------------------------------------
# modules/code-quality.sh — Code quality checks module for daily-bot
#
# Entry point: run_code_quality <repo_name> <repo_dir>
# Gated by: quality.enabled in configuration
# Checks:
#   - quality.autoflake: Remove unused imports/variables in Python files
#   - quality.ts_prune:  Find unused exports in TypeScript projects
#   - quality.mypy:      Type-check Python files
#   - quality.tsc:       Type-check TypeScript projects
#   - quality.hadolint:  Lint Dockerfile
#   - quality.yaml_lint: Validate YAML files with Python PyYAML
# ------------------------------------------------------------------

run_code_quality() {
  local repo_name="$1"
  local repo_dir="$2"

  if ! module_enabled "quality"; then
    return 0
  fi

  if [[ -z "$repo_dir" || ! -d "$repo_dir" ]]; then
    log_error "quality module: Invalid repo directory '$repo_dir'"
    return 1
  fi

  local orig_dir
  orig_dir="$(pwd)"
  cd "$repo_dir" || return 1

  log_info "Running code-quality checks for $repo_name..."

  # 1. quality.autoflake
  if [[ "$(cfg_get "quality.autoflake")" == "true" ]]; then
    if command -v autoflake &>/dev/null && find . -type f -name "*.py" -not -path "*/.*" | grep -q .; then
      log_info "Running autoflake..."
      autoflake --in-place --remove-all-unused-imports --remove-unused-variables -r . || true

      local pr_mode
      pr_mode=$(cfg_get "quality.autoflake_pr_mode")
      if [[ "$pr_mode" == "true" ]]; then
        git add -A
        local preview
        preview=$(diff_preview 150)
        local pr_body
        pr_body=$(printf '## Autoflake: Remove unused imports and variables\n\nAutomated cleanup by daily-bot. Please review carefully — dynamic imports (e.g. via `getattr`, `importlib`, `__all__`) may be incorrectly removed.\n\n### Changes\n\n%s' "$preview")
        if propose_as_pr "$repo_name" "autoflake" "fix: remove unused imports and variables" "$pr_body"; then
          log_summary "$repo_name" "quality" "autoflake" "Proposed unused import removal as PR"
        fi
      else
        if commit_and_push "fix: remove unused imports and variables"; then
          log_info "autoflake: removed unused imports and variables"
          log_summary "$repo_name" "quality" "autoflake" "Removed unused imports and variables"
        fi
      fi
    fi
  fi

  # 2. quality.ts_prune
  if [[ "$(cfg_get "quality.ts_prune")" == "true" ]]; then
    if [[ -f "tsconfig.json" ]] && (command -v ts-prune &>/dev/null || command -v npx &>/dev/null); then
      log_info "Running ts-prune..."
      local ts_prune_output
      ts_prune_output=$(npx --yes ts-prune 2>&1 || true)
      local unused_count=0
      if [[ -n "$ts_prune_output" ]]; then
        unused_count=$(echo "$ts_prune_output" | grep -v '^\s*$' | wc -l | tr -d ' ')
      fi
      if [[ "$unused_count" -gt 0 ]]; then
        log_info "ts-prune: found $unused_count unused export(s)"
        log_summary "$repo_name" "quality" "ts_prune" "Found $unused_count unused export(s)"
      else
        log_summary "$repo_name" "quality" "ts_prune" "No unused exports found"
      fi
    fi
  fi

  # 3. quality.mypy
  if [[ "$(cfg_get "quality.mypy")" == "true" ]]; then
    if command -v mypy &>/dev/null && find . -type f -name "*.py" -not -path "*/.*" | grep -q .; then
      log_info "Running mypy..."
      local mypy_output
      mypy_output=$(mypy . --ignore-missing-imports --no-error-summary 2>&1 || true)
      local error_count=0
      if [[ -n "$mypy_output" ]]; then
        error_count=$(echo "$mypy_output" | grep -c ": error:" || true)
        if [[ "$error_count" -eq 0 ]]; then
          error_count=$(echo "$mypy_output" | grep -v '^\s*$' | wc -l | tr -d ' ')
        fi
      fi
      log_info "mypy: found $error_count error(s)"
      log_summary "$repo_name" "quality" "mypy" "Found $error_count error(s)"
    fi
  fi

  # 4. quality.tsc
  if [[ "$(cfg_get "quality.tsc")" == "true" ]]; then
    if [[ -f "tsconfig.json" ]] && (command -v tsc &>/dev/null || command -v npx &>/dev/null); then
      log_info "Running tsc..."
      local tsc_output
      tsc_output=$(npx --yes tsc --noEmit 2>&1 || true)
      local tsc_error_count=0
      if [[ -n "$tsc_output" ]]; then
        tsc_error_count=$(echo "$tsc_output" | grep -c "error TS" || true)
        if [[ "$tsc_error_count" -eq 0 ]]; then
          tsc_error_count=$(echo "$tsc_output" | grep -v '^\s*$' | wc -l | tr -d ' ')
        fi
      fi
      log_info "tsc: found $tsc_error_count error(s)"
      log_summary "$repo_name" "quality" "tsc" "Found $tsc_error_count error(s)"
    fi
  fi

  # 5. quality.hadolint
  if [[ "$(cfg_get "quality.hadolint")" == "true" ]]; then
    if [[ -f "Dockerfile" ]] && command -v hadolint &>/dev/null; then
      log_info "Running hadolint..."
      local hadolint_output
      hadolint_output=$(hadolint Dockerfile 2>&1 || true)
      local warning_count=0
      if [[ -n "$hadolint_output" ]]; then
        warning_count=$(echo "$hadolint_output" | grep -v '^\s*$' | wc -l | tr -d ' ')
      fi
      log_info "hadolint: found $warning_count warning(s)"
      log_summary "$repo_name" "quality" "hadolint" "Found $warning_count warning(s)"
    fi
  fi

  # 6. quality.yaml_lint
  if [[ "$(cfg_get "quality.yaml_lint")" == "true" ]]; then
    if command -v python3 &>/dev/null; then
      local yaml_files=()
      while IFS= read -r -d '' f; do
        yaml_files+=("$f")
      done < <(find . -type f \( -name "*.yml" -o -name "*.yaml" \) -not -path "*/.*" -not -path "*/node_modules/*" -print0 2>/dev/null)

      if [[ ${#yaml_files[@]} -gt 0 ]]; then
        log_info "yaml_lint: validating ${#yaml_files[@]} YAML file(s)..."
        local invalid_files=()
        for f in "${yaml_files[@]}"; do
          if ! python3 -c "import yaml, sys; yaml.safe_load(open(sys.argv[1]))" "$f" &>/dev/null; then
            invalid_files+=("$f")
          fi
        done

        if [[ ${#invalid_files[@]} -gt 0 ]]; then
          local invalid_list
          invalid_list=$(IFS=', '; echo "${invalid_files[*]}")
          log_warn "yaml_lint: found invalid YAML file(s): $invalid_list"
          log_summary "$repo_name" "quality" "yaml_lint" "Invalid YAML file(s): $invalid_list"
        else
          log_summary "$repo_name" "quality" "yaml_lint" "All ${#yaml_files[@]} YAML file(s) valid"
        fi
      fi
    fi
  fi
  # 7. quality.depcheck — Find unused dependencies in JS/TS projects
  if [[ "$(cfg_get "quality.depcheck")" == "true" ]]; then
    if [[ -f "package.json" ]] && command -v npx &>/dev/null; then
      log_info "Running depcheck for ${repo_name}..."
      local depcheck_output
      depcheck_output=$(npx --yes depcheck --json 2>/dev/null || true)
      if [[ -n "$depcheck_output" && "$depcheck_output" != "{}" ]]; then
        local unused_deps missing_deps
        unused_deps=$(echo "$depcheck_output" | python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    deps = d.get('dependencies', []) + d.get('devDependencies', [])
    print(len(deps))
except: print(0)
" 2>/dev/null || echo "0")
        missing_deps=$(echo "$depcheck_output" | python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    print(len(d.get('missing', {})))
except: print(0)
" 2>/dev/null || echo "0")
        if [[ "$unused_deps" -gt 0 || "$missing_deps" -gt 0 ]]; then
          log_info "depcheck: ${unused_deps} unused deps, ${missing_deps} missing deps in ${repo_name}"
          log_summary "$repo_name" "quality" "depcheck" "Unused: ${unused_deps}, Missing: ${missing_deps}"
        else
          log_summary "$repo_name" "quality" "depcheck" "No unused or missing dependencies"
        fi
      fi
    fi
  fi

  # 8. quality.vulture — Find unused Python code (functions, variables, imports)
  if [[ "$(cfg_get "quality.vulture")" == "true" ]]; then
    if command -v vulture &>/dev/null && find . -type f -name "*.py" -not -path "*/.*" | grep -q .; then
      log_info "Running vulture for ${repo_name}..."
      local vulture_output
      vulture_output=$(vulture . --min-confidence 80 2>&1 || true)
      local dead_code_count=0
      if [[ -n "$vulture_output" ]]; then
        dead_code_count=$(echo "$vulture_output" | grep -v '^\s*$' | wc -l | tr -d ' ')
      fi
      if [[ "$dead_code_count" -gt 0 ]]; then
        log_info "vulture: found ${dead_code_count} dead code item(s) in ${repo_name}"
        log_summary "$repo_name" "quality" "vulture" "Found ${dead_code_count} dead code item(s)"
      else
        log_summary "$repo_name" "quality" "vulture" "No dead code detected"
      fi
    fi
  fi

  # 9. quality.radon — Python cyclomatic complexity analysis
  if [[ "$(cfg_get "quality.radon")" == "true" ]]; then
    if command -v radon &>/dev/null && find . -type f -name "*.py" -not -path "*/.*" | grep -q .; then
      log_info "Running radon complexity analysis for ${repo_name}..."
      local radon_output radon_avg
      radon_output=$(radon cc . -a -nc 2>&1 || true)
      radon_avg=$(echo "$radon_output" | grep -i 'average complexity' | tail -1 | grep -oE '[0-9]+\.?[0-9]*' | head -1 || echo "0")
      local high_complexity
      high_complexity=$(echo "$radon_output" | grep -cE ' [CDEF] \(' || echo "0")
      log_info "radon: avg complexity=${radon_avg}, high-complexity functions=${high_complexity}"
      log_summary "$repo_name" "quality" "radon" "Avg complexity: ${radon_avg}, High-complexity (C-F): ${high_complexity}"

      # Append to per-run metrics for trend tracking
      local today
      today=$(date -u +'%Y-%m-%d')
      local metrics_file="${WORKDIR:-/tmp}/quality-metrics.csv"
      echo "${today},${repo_name},complexity,${radon_avg},${high_complexity}" >> "$metrics_file"
    fi
  fi

  # 10. quality.jscpd — Code duplication detection
  if [[ "$(cfg_get "quality.jscpd")" == "true" ]]; then
    if command -v npx &>/dev/null; then
      log_info "Running jscpd duplication detection for ${repo_name}..."
      local jscpd_output jscpd_json
      jscpd_json=$(mktemp)
      npx --yes jscpd . --reporters json --output "$jscpd_json" --silent 2>/dev/null || true

      local dup_percentage="0" dup_clones="0"
      if [[ -f "${jscpd_json}/jscpd-report.json" ]]; then
        dup_percentage=$(python3 -c "
import json
try:
    with open('${jscpd_json}/jscpd-report.json') as f:
        d = json.load(f)
    stats = d.get('statistics', {})
    total = stats.get('total', {})
    print(round(total.get('percentage', 0), 2))
except: print(0)
" 2>/dev/null || echo "0")
        dup_clones=$(python3 -c "
import json
try:
    with open('${jscpd_json}/jscpd-report.json') as f:
        d = json.load(f)
    print(len(d.get('duplicates', [])))
except: print(0)
" 2>/dev/null || echo "0")
      fi
      rm -rf "$jscpd_json"

      log_info "jscpd: ${dup_percentage}% duplication, ${dup_clones} clone(s) in ${repo_name}"
      log_summary "$repo_name" "quality" "jscpd" "Duplication: ${dup_percentage}%, Clones: ${dup_clones}"

      # Append to per-run metrics for trend tracking
      local today
      today=$(date -u +'%Y-%m-%d')
      local metrics_file="${WORKDIR:-/tmp}/quality-metrics.csv"
      echo "${today},${repo_name},duplication,${dup_percentage},${dup_clones}" >> "$metrics_file"
    fi
  fi

  cd "$orig_dir" || true
  return 0
}
