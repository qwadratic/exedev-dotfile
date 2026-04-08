#!/bin/bash
# Syncs Claude Code sessions to a private git repo.
# Runs via cron on the VM. Pushes new/changed session files.
#
# Setup (once per VM):
#   git clone git@github.com:qwadratic/claude-sessions.git ~/claude-sessions
#   crontab -e → add: 0 */4 * * * ~/dotfile/sync-sessions.sh >> /tmp/sync-sessions.log 2>&1

set -euo pipefail

SESSIONS_DIR="$HOME/.claude/projects"
REPO_DIR="$HOME/claude-sessions"
VM_NAME=$(hostname 2>/dev/null || echo "unknown")

if [ ! -d "$SESSIONS_DIR" ]; then
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) No sessions directory, skipping"
  exit 0
fi

if [ ! -d "$REPO_DIR/.git" ]; then
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) Sessions repo not cloned at $REPO_DIR, skipping"
  exit 1
fi

# Sync sessions into a VM-specific subdirectory
TARGET="$REPO_DIR/$VM_NAME"
mkdir -p "$TARGET"

# rsync sessions (only .jsonl and memory files, skip node_modules-like junk)
rsync -a --include='*/' --include='*.jsonl' --include='*.md' --exclude='*' \
  "$SESSIONS_DIR/" "$TARGET/"

cd "$REPO_DIR"

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
