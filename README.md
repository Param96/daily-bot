# daily-bot 🤖

Automated daily maintenance for all your GitHub repos. Runs as a GitHub Action on a cron schedule — lints, audits, cleans up, safely applies auto-fixes, and reports.

## What It Does

| Module | Actions | Auto-fix? |
|--------|---------|-----------|
| **Lint & Format** | ESLint, Prettier, Black | ✅ Yes |
| **Security** | `npm audit`, `pip-audit`, `gitleaks`, `trivy`, `syft` (SBOM), Secret Rotation, license check | ✅ Partial |
| **Repo Hygiene** | Stale branches/issues, branch protection audit, orphan repo detector, README/links check | ✅ Partial |
| **Code Quality** | `autoflake`, `ts-prune`, `mypy`, `tsc`, `hadolint`, YAML lint, `depcheck`, `vulture`, `radon`, `jscpd` | ✅ Partial |
| **Dependencies** | Outdated NPM and PIP dependencies | ✅ PR Mode |
| **Test & Rollback**| Run `npm test`/`pytest` after fixes; auto-revert bot commits if they break CI | N/A |
| **Reporting** | Daily summary, profile README update, SVG dashboard, `CHANGELOG.md` generation, tiered webhooks | N/A |

### 🛡️ Safety First
- **Dry-Run Mode**: See what would change before it happens.
- **Test Gates**: Runs test suites (`npm test`, `pytest`) before pushing auto-fixes.
- **Rollback**: Automatically detects if a bot commit broke CI on the `main` branch and issues an immediate revert.
- **PR Mode**: Risky auto-fixes (like unused dependency removal or unused exports) are opened as PRs rather than directly committed.
- **Self-Healing**: Malformed `.daily-bot.yml` configs in your repos won't crash the bot; it alerts you and falls back to safe defaults.

## Setup

### 1. Fork or clone this repo

```bash
git clone https://github.com/Param96/daily-bot.git
```

### 2. Create a fine-grained Personal Access Token

Go to **Settings → Developer settings → Fine-grained tokens** and create a token with:

| Permission | Access |
|------------|--------|
| **Contents** | Read and write |
| **Issues** | Read and write |
| **Pull requests** | Read and write |
| **Administration** | Read and write |
| **Actions** | Read and write |
| **Commit statuses** | Read and write |

Set **Repository access** to "All repositories" (or select the ones you want maintained).

### 3. Add secrets to your repo

Go to **Settings → Secrets and variables → Actions** and add:

| Secret | Value |
|--------|-------|
| `PAT_TOKEN` | Your Personal Access Token |
| `GH_USERNAME` | Your GitHub username (e.g., `Param96`) |
| `WEBHOOK_URL` | *(Optional)* Discord or Slack webhook URL |

### 4. Configure exclusions

Edit `exclude.txt` to list repos you don't want touched (one per line):

```text
meadow-world
some-client-project
```

### 5. Let it run

The workflow runs automatically at **03:00 UTC (08:30 IST)** daily. Or trigger it manually via **Actions → Daily Repo Maintenance → Run workflow**. You can set `dry_run: true` to test safely.

## Per-Repo Configuration

Drop a `.daily-bot.yml` in any repo's root to customize which checks run. All modules default to "safe" mode (read-only/reporting enabled, direct-commits disabled unless specified).

```yaml
# Example excerpt of .daily-bot.yml
lint:
  enabled: true
  eslint: true

security:
  enabled: true
  npm_audit_pr_mode: true       # Open PR instead of direct-commit
  trivy: true                   # Trivy filesystem/Dockerfile scan
  sbom: false                   # Generate SBOM via syft
  secret_rotation: true         # Check secrets-manifest.yml
  max_secret_age_days: 90

hygiene:
  enabled: true
  branch_protection: true       # Audit branch protection rules
  orphaned_repos: true          # Flag inactive repos
  orphan_months: 6

quality:
  enabled: true
  autoflake_pr_mode: true       # Propose PR for unused python imports
  depcheck: false               # Unused npm deps (can be slow)
  vulture: false                # Dead python code (can be noisy)
  radon: false                  # Cyclomatic complexity
  jscpd: false                  # Code duplication

testing:
  enabled: true
  pytest: true                  # Run tests after fixes

dependencies:
  enabled: false                # Open PRs for outdated dependencies

reporting:
  changelog: true               # Auto-generate CHANGELOG.md from conventional commits
  dashboard_svg: true           # Generate cross-repo SVG dashboard
```

If no `.daily-bot.yml` is present, the bot uses sensible defaults from `daily-bot.default.yml`.

## Project Structure

```text
daily-bot/
├── .github/workflows/
│   └── daily-maintenance.yml    # GitHub Actions workflow
├── modules/
│   ├── rollback.sh              # CI failure detection + auto-revert
│   ├── lint-format.sh           # ESLint, Prettier, Black
│   ├── security.sh              # audits, gitleaks, trivy, syft, secret rotation
│   ├── code-quality.sh          # autoflake, mypy, depcheck, vulture, radon, jscpd
│   ├── test-build.sh            # Post-fix test validation gates
│   ├── dependency-update.sh     # Outdated npm/pip updates via PR
│   ├── repo-hygiene.sh          # Stale tracking, branch protection, orphans
│   └── reporting.sh             # CHANGELOG, dashboard, webhooks, digests
├── lib/
│   └── utils.sh                 # Shared functions, tiered webhooks, config parsing
├── reports/                     # Auto-generated daily/weekly reports + SVG dashboard
├── stats/
│   └── repo-stats.csv           # Historical repo stats for trend tracking
├── daily-maintenance.sh         # Main orchestrator
├── daily-bot.default.yml        # Default per-repo config
├── exclude.txt                  # Repos to skip
└── README.md
```

## Reports & Notifications

### Daily Summary & SVG Dashboard
After each run, a markdown report is generated in `reports/YYYY-MM-DD.md`. A cross-repo aesthetic health dashboard is also generated at `reports/dashboard.svg` showing a composite health score for all processed repositories.

### Profile README
The bot updates a stats section in your GitHub profile README (`github.com/Param96/Param96`) automatically.

### Tiered Webhooks
If `WEBHOOK_URL` is set, the bot routes notifications:
- **Critical Tier**: Exposed secrets, stale secrets, broken CI, or failed rollbacks trigger an *immediate* ping with 🚨.
- **Routine Tier**: Formatting changes and daily stats are batched and sent once at the end of the run.

## License

MIT
