#!/bin/bash
set -euo pipefail

# Interactive wizard to create and provision a dev VM on exe.dev.
# Usage: bash setup-dev-vm.sh

DOTFILE_DIR="$(cd "$(dirname "$0")" && pwd)"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[..] $1${NC}"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; }
ask()  { echo -en "${YELLOW}$1${NC}"; read -r REPLY; }

echo ""
echo "=== Dev VM Setup Wizard ==="
echo ""

# --- Step 1: VM slug ---
ask "VM name slug (5-52 chars, lowercase, e.g. ortobor-dev): "
VM_SLUG="$REPLY"

if [ -z "$VM_SLUG" ]; then
  fail "VM slug cannot be empty"
  exit 1
fi

VM_HOST="${VM_SLUG}.exe.xyz"
echo ""

# --- Step 2: Create VM ---
warn "Creating VM '$VM_SLUG' on exe.dev (node:22 image)..."
RESULT=$(ssh exe.dev new --name="$VM_SLUG" --image=node:22 --json 2>&1) || {
  fail "VM creation failed: $RESULT"
  exit 1
}
ok "VM created: $VM_HOST"
echo "  SSH:    ssh $VM_HOST"
echo "  HTTPS:  https://$VM_HOST"
echo ""

# --- Step 3: Accept host key + test connection ---
warn "Testing SSH connection..."
ssh -o StrictHostKeyChecking=accept-new "$VM_HOST" echo "connected" 2>/dev/null || {
  fail "Cannot SSH to $VM_HOST"
  exit 1
}
ok "SSH connected"
echo ""

# --- Step 4: Copy dotfiles + run install ---
warn "Copying dotfiles to VM..."
scp -q "$DOTFILE_DIR/install.sh" \
       "$DOTFILE_DIR/.bashrc" \
       "$DOTFILE_DIR/.gitconfig" \
       "$DOTFILE_DIR/.npmrc" \
       "$DOTFILE_DIR/.node-version" \
       "$VM_HOST:/tmp/"
ssh "$VM_HOST" "mkdir -p ~/dotfile && cp /tmp/{install.sh,.bashrc,.gitconfig,.npmrc,.node-version} ~/dotfile/ && chmod +x ~/dotfile/install.sh"
ok "Dotfiles copied"
echo ""

warn "Running install.sh on VM (this takes 1-2 minutes)..."
ssh "$VM_HOST" "bash ~/dotfile/install.sh"
echo ""
ok "Tools installed"
echo ""

# --- Step 5: gh auth ---
echo "--- GitHub CLI auth ---"
ask "Run 'gh auth login' on the VM now? [Y/n]: "
if [[ ! "$REPLY" =~ ^[Nn] ]]; then
  echo "Opening interactive SSH session for gh auth..."
  echo "(Complete the device flow, then type 'exit' to continue)"
  ssh -t "$VM_HOST" "gh auth login"
  # Verify
  if ssh "$VM_HOST" "gh auth status" 2>/dev/null; then
    ok "GitHub authenticated"
  else
    warn "gh auth may not have completed — you can run 'ssh $VM_HOST gh auth login' later"
  fi
else
  warn "Skipped — run 'ssh $VM_HOST gh auth login' later"
fi
echo ""

# --- Step 6: Claude Code login ---
echo "--- Claude Code auth ---"
ask "Run 'claude login' on the VM now? (subscription login) [Y/n]: "
if [[ ! "$REPLY" =~ ^[Nn] ]]; then
  echo "Opening interactive SSH session for claude login..."
  echo "(Complete the login, then type 'exit' to continue)"
  ssh -t "$VM_HOST" "claude login"
  ok "Claude Code auth attempted"
else
  warn "Skipped — run 'ssh $VM_HOST claude login' later"
fi
echo ""

# --- Step 7: gsd skill ---
echo "--- GSD skill ---"
ask "Install GSD skill now? [Y/n]: "
if [[ ! "$REPLY" =~ ^[Nn] ]]; then
  ssh -t "$VM_HOST" "npx get-shit-done-cc"
  ok "GSD skill installed"
else
  warn "Skipped — run 'ssh $VM_HOST npx get-shit-done-cc' later"
fi
echo ""

# --- Step 8: gstack ---
echo "--- gstack ---"
ask "Install gstack now? (needs git clone + setup) [Y/n]: "
if [[ ! "$REPLY" =~ ^[Nn] ]]; then
  echo "Opening interactive SSH session for gstack setup..."
  echo "(Follow the gstack install instructions, then type 'exit')"
  ssh -t "$VM_HOST" "bash"
  if ssh "$VM_HOST" "test -d ~/.claude/skills/gstack" 2>/dev/null; then
    ok "gstack installed"
  else
    warn "gstack directory not found — may need manual setup"
  fi
else
  warn "Skipped — install gstack manually later"
fi
echo ""

# --- Step 9: VS Code SSH config ---
echo "--- VS Code Remote SSH ---"
SSH_CONFIG="$HOME/.ssh/config"
if grep -q "Host $VM_SLUG" "$SSH_CONFIG" 2>/dev/null; then
  ok "SSH config entry already exists for $VM_SLUG"
else
  ask "Add $VM_SLUG to ~/.ssh/config? [Y/n]: "
  if [[ ! "$REPLY" =~ ^[Nn] ]]; then
    cat >> "$SSH_CONFIG" << EOF

Host $VM_SLUG
  HostName $VM_HOST
  User node
EOF
    ok "Added to ~/.ssh/config — use 'Cmd+Shift+P → Remote-SSH → $VM_SLUG' in VS Code"
  else
    warn "Skipped — add manually:"
    echo "  Host $VM_SLUG"
    echo "    HostName $VM_HOST"
    echo "    User node"
  fi
fi
echo ""

# --- Final status ---
echo ""
echo "=== Final verification ==="
ssh "$VM_HOST" bash -s << 'CHECK'
echo "Node:     $(node --version)"
echo "pnpm:     $(pnpm --version)"
echo "gh:       $(gh --version 2>/dev/null | head -1)"
echo "claude:   $(claude --version 2>/dev/null || echo 'not found')"
echo "supabase: $(supabase --version 2>/dev/null || echo 'not found')"
echo "vercel:   $(vercel --version 2>/dev/null | head -1 || echo 'not found')"
echo "pm2:      $(pm2 --version 2>/dev/null || echo 'not found')"
echo "zsh:      $(zsh --version 2>/dev/null)"
echo "Disk:     $(df -h / | tail -1 | awk '{print $4 " free"}')"
echo ""
echo "gh auth:     $(gh auth status 2>&1 | head -1 || echo 'not logged in')"
echo "claude auth: $([ -f ~/.claude/.credentials.json ] && echo 'configured' || echo 'not configured')"
echo "gsd:         $([ -d ~/.claude/skills ] && ls ~/.claude/skills/ 2>/dev/null | head -5 || echo 'no skills')"
echo "gstack:      $([ -d ~/.claude/skills/gstack ] && echo 'installed' || echo 'not installed')"
CHECK
echo ""
echo "=== Setup complete ==="
echo ""
echo "  SSH:      ssh $VM_HOST"
echo "  VS Code:  Cmd+Shift+P → Remote-SSH: Connect → $VM_SLUG"
echo "  Terminal:  https://${VM_SLUG}.xterm.exe.xyz"
echo ""
