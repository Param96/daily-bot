#!/usr/bin/env bash
set -euo pipefail

export SCRIPT_DIR
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export WORKDIR
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
export DRY_RUN=false
source "$SCRIPT_DIR/lib/utils.sh"
for mod in "$SCRIPT_DIR"/modules/*.sh; do source "$mod"; done
init_summary
mkdir "$WORKDIR/repo"
cd "$WORKDIR/repo"

# Run with both Python/PyYAML and the workflow's yq on PATH.
[[ "$(cfg_get backup.enabled)" == false ]]
[[ "$(cfg_get backup.destination)" == '~/backups' ]]
[[ "$(cfg_get nonexistent.key '')" == '' ]]
printf 'backup:\n  enabled: false\n' > .daily-bot.yml
[[ "$(cfg_get backup.enabled)" == false ]]
[[ "$(cfg_get backup.destination)" == '~/backups' ]]
if module_enabled backup; then echo 'Disabled backup was enabled' >&2; exit 1; fi

# Verify helper dependencies in a fresh shell, without inherited function exports.
export SUMMARY_FILE
bash -eu -c '
  source "$SCRIPT_DIR/lib/utils.sh"
  for mod in "$SCRIPT_DIR"/modules/*.sh; do source "$mod"; done
  reset_repo_config
  [[ "$(cfg_get backup.enabled)" == false ]]
  for helper in _get_python _has_npm_test_script _compute_health_score; do
    declare -F "$helper" >/dev/null
  done
'
# The real worker entry point must honor exclusions before contacting GitHub.
export EXCLUDE_FILE="$WORKDIR/exclude.txt"
echo excluded > "$EXCLUDE_FILE"
GH_USER=example GH_TOKEN=dummy bash "$SCRIPT_DIR/daily-maintenance.sh" --worker excluded

# Reject backups inside a checkout before producing a commit-sized archive.
git init -q .
printf 'backup:\n  enabled: true\n  destination: true\n' > .daily-bot.yml
if run_backup example "$PWD"; then echo 'Unsafe backup accepted' >&2; exit 1; fi
[[ ! -f true/example-$(date -u +%Y-%m-%d).tar.gz ]]

# An external destination works; dry runs create no backup directory.
printf 'backup:\n  enabled: true\n  destination: "%s"\n' "$WORKDIR/backups" > .daily-bot.yml
run_backup example "$PWD"
tar -tzf "$WORKDIR/backups/example-$(date -u +%Y-%m-%d).tar.gz" >/dev/null
printf 'backup:\n  enabled: true\n  destination: "%s"\n' "$WORKDIR/dry-backups" > .daily-bot.yml
DRY_RUN=true run_backup example "$PWD"
[[ ! -e "$WORKDIR/dry-backups" ]]

# A rejected push must not be counted as a successful fix.
(
  git() {
    case "$1 $2" in
      'diff --cached') return 1 ;;
      'push -q') return 1 ;;
      *) return 0 ;;
    esac
  }
  DRY_RUN=false
  TOTAL_FIXES=0
  if commit_and_push 'test rejected push'; then exit 1; fi
  [[ "$TOTAL_FIXES" == 0 ]]
)
echo 'Regression checks passed'
