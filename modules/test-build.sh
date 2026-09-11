#!/usr/bin/env bash
# ------------------------------------------------------------------
# modules/test-build.sh — Test and build validation module for daily-bot
#
# Runs AFTER auto-fix modules but BEFORE the final commit.
# Validates that the repo still builds cleanly and tests pass.
#
# Entry point: run_test_build <repo_name> <repo_dir>
# ------------------------------------------------------------------

_get_python() {
  if command -v python3 &>/dev/null && python3 -c "import sys" &>/dev/null; then
    echo "python3"
  elif [[ -x "/usr/bin/python3" ]]; then
    echo "/usr/bin/python3"
  elif command -v python &>/dev/null && python -c "import sys" &>/dev/null; then
    echo "python"
  fi
}

_run_with_timeout() {
  local timeout_sec="$1"
  shift
  if command -v timeout &>/dev/null; then
    timeout "$timeout_sec" "$@"
  elif command -v gtimeout &>/dev/null; then
    gtimeout "$timeout_sec" "$@"
  else
    "$@"
  fi
}

_has_npm_build_script() {
  [[ -f package.json ]] || return 1
  local py_cmd
  py_cmd=$(_get_python)
  if [[ -n "$py_cmd" ]]; then
    "$py_cmd" -c "
import json, sys
try:
    with open('package.json') as f:
        data = json.load(f)
    sys.exit(0 if 'build' in data.get('scripts', {}) and data['scripts']['build'] else 1)
except Exception:
    sys.exit(1)
" 2>/dev/null && return 0
  fi

  if command -v jq &>/dev/null; then
    local script_val
    script_val=$(jq -r '.scripts.build // empty' package.json 2>/dev/null)
    if [[ -n "$script_val" && "$script_val" != "null" ]]; then
      return 0
    fi
  fi

  grep -q '"build":' package.json 2>/dev/null
}

_has_npm_test_script() {
  [[ -f package.json ]] || return 1
  local script_val=""
  local py_cmd
  py_cmd=$(_get_python)

  if [[ -n "$py_cmd" ]]; then
    script_val=$("$py_cmd" -c "
import json, sys
try:
    with open('package.json') as f:
        data = json.load(f)
    print(data.get('scripts', {}).get('test', ''))
except Exception:
    pass
" 2>/dev/null)
  fi

  if [[ -z "$script_val" ]] && command -v jq &>/dev/null; then
    script_val=$(jq -r '.scripts.test // empty' package.json 2>/dev/null)
  fi

  if [[ -z "$script_val" ]]; then
    script_val=$(grep -o '"test":\s*"[^"]*"' package.json 2>/dev/null | head -1)
  fi

  if [[ -z "$script_val" || "$script_val" == "null" ]]; then
    return 1
  fi

  # Check if test script is the default placeholder: echo "Error: no test specified" && exit 1
  if echo "$script_val" | grep -qi "no test specified"; then
    return 1
  fi

  return 0
}

_has_pytest_config_or_tests() {
  [[ -d "tests" ]] && return 0
  [[ -f "pytest.ini" ]] && return 0
  if [[ -f "pyproject.toml" ]] && grep -q '\[tool\.pytest' pyproject.toml 2>/dev/null; then
    return 0
  fi
  if find . -maxdepth 3 -name 'test_*.py' 2>/dev/null | grep -q .; then
    return 0
  fi
  return 1
}

run_test_build() {
  local repo_name="$1"
  local repo_dir="$2"

  if ! module_enabled "testing"; then
    log_info "Module 'testing' is disabled for ${repo_name}"
    return 0
  fi

  if [[ ! -d "$repo_dir" ]]; then
    log_error "Repository directory not found: ${repo_dir}"
    return 1
  fi

  local orig_dir
  orig_dir="$(pwd)"
  cd "$repo_dir" || return 1

  local test_passed=true

  # 1. Node.js build
  if [[ "$(cfg_get "testing.npm_build")" == "true" ]]; then
    if _has_npm_build_script; then
      log_info "Installing npm dependencies for build on ${repo_name}..."
      npm ci --ignore-scripts 2>/dev/null || npm install --ignore-scripts 2>/dev/null || true

      log_info "Running npm build for ${repo_name}..."
      local build_output exit_code=0
      build_output=$(_run_with_timeout 300 npm run build 2>&1) || exit_code=$?

      if [[ $exit_code -ne 0 ]]; then
        log_warn "npm run build failed for ${repo_name} (exit code ${exit_code})"
        test_passed=false
        log_summary "$repo_name" "test-build" "build_failed" "npm run build failed with exit code ${exit_code}"
      else
        log_info "npm run build passed for ${repo_name}"
        log_summary "$repo_name" "test-build" "build_passed" "npm run build passed successfully"
      fi
    fi
  fi

  # 2. Node.js test
  if [[ "$(cfg_get "testing.npm_test")" == "true" ]]; then
    if _has_npm_test_script; then
      if [[ ! -d "node_modules" ]]; then
        log_info "Installing npm dependencies for tests on ${repo_name}..."
        npm ci --ignore-scripts 2>/dev/null || npm install --ignore-scripts 2>/dev/null || true
      fi

      log_info "Running npm test for ${repo_name}..."
      local test_output exit_code=0
      test_output=$(_run_with_timeout 300 npm test 2>&1) || exit_code=$?

      if [[ $exit_code -ne 0 ]]; then
        log_warn "npm test failed for ${repo_name} (exit code ${exit_code})"
        test_passed=false
        log_summary "$repo_name" "test-build" "test_failed" "npm test failed with exit code ${exit_code}"
      else
        log_info "npm test passed for ${repo_name}"
        log_summary "$repo_name" "test-build" "test_passed" "npm test passed successfully"
      fi
    fi
  fi

  # 3. Python pytest
  if [[ "$(cfg_get "testing.pytest")" == "true" ]]; then
    if _has_pytest_config_or_tests; then
      local py_cmd
      py_cmd=$(_get_python)

      if [[ -n "$py_cmd" ]]; then
        log_info "Running pytest for ${repo_name}..."
        local pytest_output exit_code=0
        pytest_output=$(_run_with_timeout 120 "$py_cmd" -m pytest --tb=short -q 2>&1) || exit_code=$?

        if [[ $exit_code -ne 0 ]]; then
          log_warn "pytest failed for ${repo_name} (exit code ${exit_code})"
          test_passed=false
          log_summary "$repo_name" "test-build" "pytest_failed" "pytest failed with exit code ${exit_code}"
        else
          log_info "pytest passed for ${repo_name}"
          log_summary "$repo_name" "test-build" "pytest_passed" "pytest passed successfully"
        fi
      else
        log_warn "Python environment not found for pytest in ${repo_name}"
      fi
    fi
  fi

  # 4. Gate behavior
  local status=0
  if [[ "$test_passed" == "false" ]]; then
    status=1
    local uncommitted
    uncommitted=$(git status --porcelain 2>/dev/null)
    if [[ -n "$uncommitted" ]]; then
      git checkout -- . 2>/dev/null || true
      git clean -fd 2>/dev/null || true
      log_warn "Auto-fix changes discarded for ${repo_name} — tests/build failed"
      send_webhook_critical "Test/build validation failed for ${repo_name}. Auto-fix changes discarded."
    fi
  fi

  cd "$orig_dir" || true
  return $status
}
