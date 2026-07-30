# daily-bot

Scheduled GitHub Action that goes through your repos once a day, tries real
fixes (lint/format), and pushes a genuine housekeeping commit if nothing
needed fixing — no empty/no-op commits.

## Setup

1. Create a new repo, e.g. `Param96/daily-bot`, and push these files to it:
   - `.github/workflows/daily-maintenance.yml`
   - `scripts/daily-maintenance.sh`
   - `exclude.txt`

2. Make the script executable:
   ```
   chmod +x scripts/daily-maintenance.sh
   ```

3. Create a fine-grained Personal Access Token:
   - Settings -> Developer settings -> Fine-grained tokens
   - Repository access: All repos (or just the ones you want touched)
   - Permissions: **Contents: Read and write**

4. In `daily-bot` repo settings -> Secrets and variables -> Actions, add:
   - `PAT_TOKEN` = the token from step 3
   - `GH_USERNAME` = `Param96`

5. Edit `exclude.txt` to list any repos you don't want touched
   (forks, client work, archived stuff, `meadow-world` if you'd rather
   hand-review those commits, etc).

6. Test it manually first: Actions tab -> "Daily Repo Maintenance" ->
   "Run workflow" -> set `dry_run: true`. Check the logs to see what it
   *would* have done before letting it push for real.

7. Once you're happy, trigger it again with `dry_run: false`, or just let
   the 03:00 UTC cron handle it.

## What it does per repo

- Clones fresh (no state kept between runs)
- JS/TS: runs `eslint --fix` and `prettier --write` if configs exist
- Python: runs `black .`
- If that produced real diffs -> commits as `fix: automated lint/format fixes`
- If not -> appends one line to `daily-log.md` in that repo and commits as
  `chore: daily maintenance check`

## Extending it

- Add a markdown dead-link checker (e.g. `lychee`) as another fix step
- Add `npm audit fix` for dependency patches
- Swap the fallback log entry for something more useful, like pinging an
  uptime check or regenerating a stats file, if you want every day's
  commit to carry real information
