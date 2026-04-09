#!/bin/bash
# Syncs Claude Code sessions + gstack data to a private git repo.
# Each machine pushes to its own branch — no clone needed, no cross-contamination.
# Runs via cron/pm2. Pushes new/changed files every 4 hours.
#
# First run auto-initializes a local repo with the remote.
# No git pull, no full clone — push-only.

set -euo pipefail

SESSIONS_DIR="$HOME/.claude/projects"
GSTACK_DIR="$HOME/.gstack"
REPO_DIR="$HOME/claude-sessions"
REMOTE="git@github.com:qwadratic/claude-sessions.git"
VM_NAME=${SYNC_HOSTNAME:-$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo "unknown")}
BRANCH="sessions/${VM_NAME}"

# Auto-initialize on first run (no clone needed)
if [ ! -d "$REPO_DIR/.git" ]; then
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) Initializing session sync repo"
  mkdir -p "$REPO_DIR"
  cd "$REPO_DIR"
  git init -q
  git remote add origin "$REMOTE"
  git checkout -b "$BRANCH"
else
  cd "$REPO_DIR"
  # Ensure we're on the right branch
  CURRENT=$(git branch --show-current 2>/dev/null || echo "")
  if [ "$CURRENT" != "$BRANCH" ]; then
    git checkout -B "$BRANCH" 2>/dev/null
  fi
fi

# Sync Claude Code sessions (.jsonl + memory .md files)
if [ -d "$SESSIONS_DIR" ]; then
  mkdir -p "$REPO_DIR/claude-sessions"
  rsync -a --include='*/' --include='*.jsonl' --include='*.md' --exclude='*' \
    "$SESSIONS_DIR/" "$REPO_DIR/claude-sessions/"
fi

# Sync gstack data (projects, analytics, config — skip browser profiles)
if [ -d "$GSTACK_DIR" ]; then
  mkdir -p "$REPO_DIR/gstack"
  rsync -a \
    --exclude='chromium-profile/' \
    --exclude='cdp-profile/' \
    --exclude='worktrees/' \
    --exclude='sessions/' \
    "$GSTACK_DIR/" "$REPO_DIR/gstack/"
fi

# Check if anything changed
if git diff --quiet && [ -z "$(git ls-files --others --exclude-standard)" ]; then
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) No new sessions to sync"
  exit 0
fi

# Count new/changed files
CHANGED=$(git status --porcelain | wc -l | tr -d ' ')

git add -A
git commit -m "sync: ${VM_NAME} — ${CHANGED} files — $(date -u +%Y-%m-%dT%H:%M:%SZ)" --no-gpg-sign
git push --force -u origin "$BRANCH"

echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) Synced ${CHANGED} files from ${VM_NAME} to ${BRANCH}"
