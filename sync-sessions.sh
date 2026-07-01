#!/bin/bash
# Syncs coding-agent sessions (Claude Code, Codex, Pi) + gstack legacy tree
# to a private git repo. Each machine pushes to its own branch — no clone
# needed, no cross-contamination. Runs via launchd every 4 hours.
#
# First run auto-initializes a local repo with the remote.
# Push-only; no git pull.
#
# Sources synced (all skipped if missing → won't cause deletions):
#   ~/.claude/projects       → claude-sessions/   (jsonl + md only)
#   ~/.codex/sessions        → codex/sessions/    (jsonl)
#   ~/.codex/archived_sessions → codex/archived_sessions/ (jsonl)
#   ~/.pi/agent/sessions     → pi/sessions/       (jsonl)
#   ~/.gstack                → gstack/            (legacy — only if dir exists)

set -euo pipefail

REPO_DIR="$HOME/claude-sessions"
REMOTE="git@github.com:qwadratic/claude-sessions.git"
VM_NAME=${SYNC_HOSTNAME:-$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo "unknown")}
BRANCH="sessions/${VM_NAME}"

CLAUDE_SESSIONS_DIR="$HOME/.claude/projects"
CODEX_SESSIONS_DIR="$HOME/.codex/sessions"
CODEX_ARCHIVED_DIR="$HOME/.codex/archived_sessions"
PI_SESSIONS_DIR="$HOME/.pi/agent/sessions"
GSTACK_DIR="$HOME/.gstack"

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
  CURRENT=$(git branch --show-current 2>/dev/null || echo "")
  if [ "$CURRENT" != "$BRANCH" ]; then
    git checkout -B "$BRANCH" 2>/dev/null
  fi
fi

# --- Claude Code sessions (.jsonl + memory .md files) ---
if [ -d "$CLAUDE_SESSIONS_DIR" ]; then
  mkdir -p "$REPO_DIR/claude-sessions"
  rsync -a --include='*/' --include='*.jsonl' --include='*.md' --exclude='*' \
    "$CLAUDE_SESSIONS_DIR/" "$REPO_DIR/claude-sessions/"
fi

# --- Codex sessions (.jsonl) ---
if [ -d "$CODEX_SESSIONS_DIR" ]; then
  mkdir -p "$REPO_DIR/codex/sessions"
  rsync -a --include='*/' --include='*.jsonl' --exclude='*' \
    "$CODEX_SESSIONS_DIR/" "$REPO_DIR/codex/sessions/"
fi
if [ -d "$CODEX_ARCHIVED_DIR" ]; then
  mkdir -p "$REPO_DIR/codex/archived_sessions"
  rsync -a --include='*/' --include='*.jsonl' --exclude='*' \
    "$CODEX_ARCHIVED_DIR/" "$REPO_DIR/codex/archived_sessions/"
fi

# --- Pi coding-agent sessions (.jsonl) ---
if [ -d "$PI_SESSIONS_DIR" ]; then
  mkdir -p "$REPO_DIR/pi/sessions"
  rsync -a --include='*/' --include='*.jsonl' --exclude='*' \
    "$PI_SESSIONS_DIR/" "$REPO_DIR/pi/sessions/"
fi

# --- gstack legacy tree (only synced if ~/.gstack still exists) ---
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

CHANGED=$(git status --porcelain | wc -l | tr -d ' ')

git add -A
git commit -m "sync: ${VM_NAME} — ${CHANGED} files — $(date -u +%Y-%m-%dT%H:%M:%SZ)" --no-gpg-sign
git push --force -u origin "$BRANCH"

echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) Synced ${CHANGED} files from ${VM_NAME} to ${BRANCH}"
