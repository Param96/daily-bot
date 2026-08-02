# daily-bot 🤖

Automated daily maintenance for all your GitHub repos. Runs as a GitHub Action on a cron schedule — lints, audits, cleans up, and reports.

## What It Does

| Module | Actions | Auto-fix? |
|--------|---------|-----------|
| **Lint & Format** | ESLint, Prettier, Black | ✅ Yes |
| **Security** | `npm audit`, `pip-audit`, `gitleaks`, license check | ✅ Partial |
| **Repo Hygiene** | Stale branches, stale issues/PRs, README check, broken links | ✅ Partial |
| **Code Quality** | `autoflake`, `ts-prune`, `mypy`, `tsc`, `hadolint`, YAML lint | ✅ Partial |
| **Reporting** | Daily summary, profile README update, stats CSV, webhook | N/A |

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

```
meadow-world
some-client-project
```

### 5. Test it

Go to **Actions → Daily Repo Maintenance → Run workflow** and set `dry_run: true`.
Check the logs to see what it *would* do before letting it run for real.

### 6. Let it run

The workflow runs automatically at **03:00 UTC (08:30 IST)** daily. Or trigger it manually anytime.

## Per-Repo Configuration

Drop a `.daily-bot.yml` in any repo's root to customize which checks run:

```yaml
lint:
  enabled: true
  eslint: true
  prettier: true
  black: true

security:
  enabled: true
  npm_audit: true
  pip_audit: true
  gitleaks: true
  license_check: true

hygiene:
  enabled: true
  stale_branches: true
  stale_branch_days: 90
  stale_issues: true
  stale_issue_days: 30
  readme_check: true
  broken_links: true

quality:
  enabled: true
  autoflake: true
  ts_prune: true
  mypy: false          # off by default (can be noisy)
  tsc: false           # off by default (can be noisy)
  hadolint: true
  yaml_lint: true
```

If no `.daily-bot.yml` is present, the bot uses sensible defaults from `daily-bot.default.yml`.

## Project Structure

```
daily-bot/
├── .github/workflows/
│   └── daily-maintenance.yml    # GitHub Actions workflow
├── modules/
│   ├── lint-format.sh           # ESLint, Prettier, Black
│   ├── security.sh              # npm audit, pip-audit, gitleaks, license
│   ├── repo-hygiene.sh          # Stale branches/issues, README, broken links
│   ├── code-quality.sh          # autoflake, ts-prune, mypy, tsc, hadolint, YAML
│   └── reporting.sh             # Summary, profile README, stats, webhook
├── lib/
│   └── utils.sh                 # Shared functions, config parser, pagination
├── reports/                     # Auto-generated daily reports (YYYY-MM-DD.md)
├── stats/
│   └── repo-stats.csv           # Historical repo stats for trend tracking
├── daily-maintenance.sh         # Main orchestrator
├── daily-bot.default.yml        # Default per-repo config
├── exclude.txt                  # Repos to skip
└── README.md
```

## Reports & Notifications

### Daily Summary Reports

After each run, a markdown report is generated in `reports/YYYY-MM-DD.md` with:
- Total repos checked, fixes pushed, errors encountered
- Per-repo breakdown of all actions taken

### Profile README

The bot updates a stats section in your GitHub profile README (`github.com/Param96/Param96`) between these markers:

```markdown
<!-- DAILY-BOT:START -->
(auto-generated stats appear here)
<!-- DAILY-BOT:END -->
```

### Stats Dashboard

Repo metrics (stars, forks, open issues) are appended daily to `stats/repo-stats.csv` for trend tracking.

### Webhook Notifications

If `WEBHOOK_URL` is set, the bot posts a summary to Discord or Slack after each run, and alerts on workflow failures.

## Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `GH_USER` | ✅ | — | GitHub username |
| `GH_TOKEN` | ✅ | — | Personal Access Token |
| `DRY_RUN` | ❌ | `false` | Skip all pushes, just log |
| `WEBHOOK_URL` | ❌ | — | Discord/Slack webhook URL |
| `PARALLEL_WORKERS` | ❌ | `4` | Number of parallel workers |

## License

MIT
