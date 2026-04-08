#!/bin/bash
# Syncs Claude Code sessions + gstack data to a private git repo.
# Runs via cron/pm2. Pushes new/changed files every 4 hours.
#
# Setup (once per machine):
#   git clone git@github.com:qwadratic/claude-sessions.git ~/claude-sessions

set -euo pipefail

SESSIONS_DIR="$HOME/.claude/projects"
GSTACK_DIR="$HOME/.gstack"
REPO_DIR="$HOME/claude-sessions"
VM_NAME=${SYNC_HOSTNAME:-$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo "unknown")}

if [ ! -d "$REPO_DIR/.git" ]; then
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) Sessions repo not cloned at $REPO_DIR, skipping"
  exit 1
fi

TARGET="$REPO_DIR/$VM_NAME"
mkdir -p "$TARGET"

# Sync Claude Code sessions (.jsonl + memory .md files)
if [ -d "$SESSIONS_DIR" ]; then
  rsync -a --include='*/' --include='*.jsonl' --include='*.md' --exclude='*' \
    "$SESSIONS_DIR/" "$TARGET/claude-sessions/"
fi

# Sync gstack data (projects, analytics, config — skip browser profiles)
if [ -d "$GSTACK_DIR" ]; then
  rsync -a \
    --exclude='chromium-profile/' \
    --exclude='cdp-profile/' \
    --exclude='worktrees/' \
    --exclude='sessions/' \
    "$GSTACK_DIR/" "$TARGET/gstack/"
fi

cd "$REPO_DIR"

# Pull latest from other machines
git pull --rebase --quiet origin main 2>/dev/null || true

# Check if anything changed
if git diff --quiet && [ -z "$(git ls-files --others --exclude-standard)" ]; then
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) No new sessions to sync"
  exit 0
fi

# Count new/changed files
CHANGED=$(git status --porcelain | wc -l | tr -d ' ')

git add -A
git commit -m "sync: ${VM_NAME} — ${CHANGED} files — $(date -u +%Y-%m-%dT%H:%M:%SZ)" --no-gpg-sign
git push origin main

echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) Synced ${CHANGED} files from ${VM_NAME}"
