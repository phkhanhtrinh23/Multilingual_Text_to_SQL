#!/usr/bin/env bash
# Install per-repo auto sync (ALWAYS uses `main`) + copy external databases folder every minute.
# Flow each run:
#   0) Copy external databases → repo databases
#   1) Commit local edits on main FIRST
#   2) fetch → rebase main onto origin/main
#   3) push main to origin
#   4) cron: every 1 minute
set -Eeuo pipefail
echo "[setup] starting…"

export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"

# Normalize CRLF in THIS file (harmless if already LF)
if grep -q $'\r' "$0" 2>/dev/null; then
  sed -i 's/\r$//' "$0"
fi

# --- Verify repo ---
REPO_DIR="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$REPO_DIR" ]; then
  echo "❌ Not inside a git repository. cd into your repo (/mnt/win_d/Multilingual_Text_to_SQL) and re-run."
  exit 1
fi
cd "$REPO_DIR"

# --- Remote sanity (default: origin) ---
REMOTE="origin"
if ! git remote get-url "$REMOTE" >/dev/null 2>&1; then
  echo "❌ Remote 'origin' not found."
  echo "   Add it, e.g.: git remote add origin git@github.com:<USER>/<REPO>.git"
  exit 1
fi
REMOTE_URL="$(git remote get-url "$REMOTE" 2>/dev/null || true)"

SCRIPT="$REPO_DIR/.git/auto-git-sync.sh"
LOG="$REPO_DIR/.git/auto-sync.log"

# --- Write the per-repo sync script (copy → commit on main → fetch/rebase → push) ---
cat > "$SCRIPT" <<'EOS'
#!/usr/bin/env bash
# Copy external DBs → commit on main → fetch/rebase → push (minutely via cron)
set -Eeuo pipefail
export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"

REPO_DIR="__REPO_DIR__"
REMOTE="origin"
TARGET_BRANCH="main"

# Paths to sync (as requested)
SRC_DIR="/mnt/win_d/Multilingual_Text_to_SQL_code_backend/mt2sql_output/databases"
DST_DIR="/mnt/win_d/Multilingual_Text_to_SQL/databases"

LOG_FILE="$REPO_DIR/.git/auto-sync.log"
LOCK_FILE="$REPO_DIR/.git/auto-sync.lock"

mkdir -p "$(dirname "$LOG_FILE")"

# Log (tee to terminal when VERBOSE=1)
if [ "${VERBOSE:-0}" = "1" ]; then exec > >(tee -a "$LOG_FILE") 2>&1; else exec >>"$LOG_FILE" 2>&1; fi

# One-run-at-a-time (best-effort)
if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    echo "$(date -Is) Another auto-git-sync is running; skipping."
    exit 0
  fi
fi

echo "===== $(date -Is) ====="
cd "$REPO_DIR"
git rev-parse --is-inside-work-tree >/dev/null

# Ensure identity (only if unset)
git config user.name  "${GIT_AUTHOR_NAME:-Auto Sync Bot}" >/dev/null || true
git config user.email "${GIT_AUTHOR_EMAIL:-auto-sync@example}" >/dev/null || true

# Detect current branch and dirtiness
CUR_BRANCH="$(git rev-parse --abbrev-ref HEAD || echo HEAD)"
DIRTY=0
if ! git diff --quiet || ! git diff --cached --quiet || [ -n "$(git ls-files --others --exclude-standard)" ]; then
  DIRTY=1
fi

# If not on main, stash edits FIRST (so we can move them to main cleanly)
STASHED=0
if [ "$CUR_BRANCH" != "$TARGET_BRANCH" ] && [ "$CUR_BRANCH" != "HEAD" ] && [ "$DIRTY" -eq 1 ]; then
  echo "Dirty tree on '$CUR_BRANCH'; stashing before switching to '$TARGET_BRANCH'..."
  git stash push -u -m "autosync-to-main $(date -Is)" || true
  STASHED=1
fi

# Checkout main (create or track origin/main if needed)
if git rev-parse --verify "refs/heads/$TARGET_BRANCH" >/dev/null 2>&1; then
  git checkout -q "$TARGET_BRANCH"
elif git show-ref --verify --quiet "refs/remotes/$REMOTE/$TARGET_BRANCH"; then
  git checkout -q -t "$REMOTE/$TARGET_BRANCH"
else
  git checkout -q -b "$TARGET_BRANCH"
fi

# If we stashed from another branch, bring the edits into main now
if [ "$STASHED" -eq 1 ]; then
  echo "Restoring stashed edits onto '$TARGET_BRANCH'…"
  if ! git stash pop --index; then
    echo "Conflicts applying stash to '$TARGET_BRANCH'; resolve manually."
    exit 0
  fi
fi

# ---- 0) COPY external databases into repo before committing ----
if [ -d "$SRC_DIR" ]; then
  mkdir -p "$DST_DIR"
  echo "Syncing databases: $SRC_DIR  →  $DST_DIR"
  if command -v rsync >/dev/null 2>&1; then
    # keep in sync, remove deletions, avoid copying any nested .git by accident
    rsync -a --delete --exclude='.git' "$SRC_DIR"/ "$DST_DIR"/
  else
    # fallback (no delete): best-effort mirror
    cp -a "$SRC_DIR"/. "$DST_DIR"/
  fi
else
  echo "⚠️  Source folder missing: $SRC_DIR  (copy step skipped)"
fi

# ---- 1) Commit local edits on main FIRST ----
echo "Status before add (on $TARGET_BRANCH):"; git status --porcelain=v1
git add -A
if ! git diff --cached --quiet; then
  git commit -m "Auto commit (pre-sync on main): $(date -Is)"
else
  echo "No local changes before sync."
fi

# ---- 2) Fetch & rebase main onto origin/main ----
git fetch "$REMOTE" --prune
if git rev-parse --verify "refs/remotes/$REMOTE/$TARGET_BRANCH" >/dev/null 2>&1; then
  if ! git rebase "$REMOTE/$TARGET_BRANCH"; then
    echo "Rebase conflict; aborting rebase."
    git rebase --abort || true
    exit 0
  fi
fi

# ---- 3) Push main (set upstream if missing) ----
if ! git push -u "$REMOTE" "$TARGET_BRANCH"; then
  echo "Push failed (auth/remote moved). Will retry on next run."
  exit 0
fi

echo "Done."
EOS

# Fill placeholders, normalize, make executable
sed -i "s#__REPO_DIR__#${REPO_DIR//\//\\/}#g" "$SCRIPT"
sed -i 's/\r$//' "$SCRIPT"
chmod +x "$SCRIPT"

# --- Install/refresh the EVERY-MINUTE cron line ---
if ! command -v crontab >/dev/null 2>&1; then
  echo "❌ 'crontab' not found. Install & start cron first."
  echo "   Ubuntu/Debian:  sudo apt install -y cron && sudo systemctl enable --now cron"
  echo "   Fedora/RHEL:    sudo dnf install -y cronie && sudo systemctl enable --now crond"
  echo "   Arch:           sudo pacman -S cronie && sudo systemctl enable --now cronie"
  echo "   Alpine:         sudo apk add dcron && sudo rc-update add crond && sudo rc-service crond start"
else
  CRON_LINE="* * * * * PATH=/usr/local/bin:/usr/bin:/bin /usr/bin/env bash \"$SCRIPT\""
  ( crontab -l 2>/dev/null | grep -v -F "$SCRIPT" ; echo "$CRON_LINE" ) | crontab -
fi

# --- First run now (verbose so you can see it) ---
echo "[setup] running initial sync (verbose)…"
VERBOSE=1 bash "$SCRIPT" || true

# --- Show evidence: crontab + log tail ---
echo
echo "✅ Auto-sync installed for:"
echo "   Repo   : $REPO_DIR"
echo "   Remote : $REMOTE ($REMOTE_URL)"
echo "   Branch : main"
echo "   Cron   : * * * * * PATH=/usr/local/bin:/usr/bin:/bin /usr/bin/env bash \"$SCRIPT\""
echo "   Log    : $LOG"
echo
echo "---- crontab -l ----"
crontab -l 2>/dev/null | sed "s|$HOME|~|g" || true
echo "---- tail -n 60 $LOG ----"
tail -n 60 "$LOG" || true

# HTTPS warning (cron can’t answer prompts)
if [[ "$REMOTE_URL" =~ ^https:// ]]; then
  cat <<'NOTE'

⚠️  Your remote uses HTTPS. Cron cannot answer username/password prompts.
   Prefer SSH:
     git remote set-url origin git@github.com:<USER>/<REPO>.git
   (Need an SSH key? I can give you a 30-sec setup snippet.)
NOTE
fi

# Cron service hint (systemd machines)
if command -v systemctl >/dev/null 2>&1; then
  if systemctl list-unit-files | grep -Eq '^(cron|crond|cronie)\.service'; then
    if ! (systemctl is-active --quiet cron 2>/dev/null || systemctl is-active --quiet crond 2>/dev/null || systemctl is-active --quiet cronie 2>/dev/null); then
      echo "⚠️  Cron service looks INACTIVE."
      echo "   Start it: sudo systemctl enable --now cron    # Debian/Ubuntu"
      echo "             sudo systemctl enable --now crond   # Fedora/CentOS/Arch"
    fi
  fi
fi

echo "[setup] done."
