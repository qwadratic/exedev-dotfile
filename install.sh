#!/bin/bash
set -euo pipefail

# Non-interactive install script for dev VM tools.
# Called by setup-dev-vm.sh after VM creation.
# Can also be run standalone on an existing VM.
#
# Strategy:
#   Phase 1 (root): apt packages, create dev user, install global binaries
#   Phase 2 (root): give dev user ownership of global tools, set up auto-switch
#   Phase 3 (dev):  dotfiles, claude settings, session sync, pm2

DOTFILE_DIR="$(cd "$(dirname "$0")" && pwd)"
DEV_HOME="/home/dev"

echo "=== Dev VM Bootstrap ==="

# ============================================================
# PHASE 1: Root — system packages + global binaries
# ============================================================

echo "--- System packages ---"
apt-get update -qq
apt-get install -y -qq git curl jq rsync 2>/dev/null

echo "--- Dev user ---"
if id dev &>/dev/null; then
  echo "dev user exists"
else
  useradd -m -s /bin/bash dev
  echo "dev user created"
fi

echo "--- corepack + pnpm ---"
corepack enable 2>/dev/null || npm install -g corepack && corepack enable
COREPACK_ENABLE_AUTO_PIN=0 corepack prepare pnpm@latest --activate
echo "Node: $(node --version), pnpm: $(pnpm --version)"

echo "--- gh CLI ---"
if ! command -v gh &>/dev/null; then
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg 2>/dev/null
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null
  apt-get update -qq && apt-get install -y -qq gh
fi
echo "gh: $(gh --version | head -1)"

echo "--- Claude Code ---"
if ! command -v claude &>/dev/null; then
  npm install -g @anthropic-ai/claude-code
fi
echo "claude: $(claude --version 2>/dev/null || echo 'installed')"

echo "--- Supabase CLI ---"
if ! command -v supabase &>/dev/null; then
  ARCH=$(dpkg --print-architecture)
  SB_VERSION=$(curl -sf https://api.github.com/repos/supabase/cli/releases/latest | jq -r '.tag_name // empty' | sed 's/^v//' 2>/dev/null || echo "")
  [ -z "$SB_VERSION" ] && SB_VERSION="2.20.12"
  echo "Installing supabase v${SB_VERSION}"
  curl -fsSL "https://github.com/supabase/cli/releases/download/v${SB_VERSION}/supabase_linux_${ARCH}.tar.gz" -o /tmp/supabase.tar.gz
  tar -xzf /tmp/supabase.tar.gz -C /usr/local/bin supabase
  rm /tmp/supabase.tar.gz
fi
echo "supabase: $(supabase --version 2>/dev/null)"

echo "--- Vercel CLI ---"
if ! command -v vercel &>/dev/null; then
  npm install -g vercel
fi
echo "vercel: $(vercel --version 2>/dev/null | head -1)"

echo "--- pm2 ---"
if ! command -v pm2 &>/dev/null; then
  npm install -g pm2
fi
echo "pm2: $(pm2 --version 2>/dev/null)"

# ============================================================
# PHASE 2: Root — hand ownership to dev, set up auto-switch
# ============================================================

echo "--- Permissions ---"
# Give dev user ownership of npm globals so auto-updates work
chown -R dev:dev /usr/local/lib/node_modules/ 2>/dev/null || true
chown dev:dev /usr/local/bin/claude /usr/local/bin/vercel /usr/local/bin/pm2 2>/dev/null || true

# Auto-switch root → dev on interactive SSH (exe.dev sshd forces root)
if ! grep -q "exec su - dev" ~/.profile 2>/dev/null; then
  sed -i '1a\# Auto-switch to dev user (Claude Code needs non-root for yolo mode)\nif [ "$(whoami)" = "root" ] \&\& [ -d /exe.dev ] \&\& [ -n "$SSH_CONNECTION" ] \&\& [ -t 0 ]; then exec su - dev; fi\n' ~/.profile
fi
# Also cover zsh (exe.dev may set it as default shell)
if ! grep -q "exec su - dev" ~/.zshrc 2>/dev/null; then
  echo 'if [ "$(whoami)" = "root" ] && [ -d /exe.dev ] && [ -n "$SSH_CONNECTION" ] && [ -t 0 ]; then exec su - dev; fi' > ~/.zshrc
fi

# Copy dotfiles to dev user
if [ ! -d "$DEV_HOME/dotfile" ]; then
  cp -r "$DOTFILE_DIR" "$DEV_HOME/dotfile"
fi
cp "$DOTFILE_DIR/.bashrc" "$DEV_HOME/dotfile/.bashrc" 2>/dev/null || true
cp "$DOTFILE_DIR/.gitconfig" "$DEV_HOME/dotfile/.gitconfig" 2>/dev/null || true
cp "$DOTFILE_DIR/.npmrc" "$DEV_HOME/dotfile/.npmrc" 2>/dev/null || true

# Source dotfile .bashrc
if ! grep -q "dotfile/.bashrc" "$DEV_HOME/.bashrc" 2>/dev/null; then
  echo '[ -f ~/dotfile/.bashrc ] && source ~/dotfile/.bashrc' >> "$DEV_HOME/.bashrc"
fi

# Symlink dotfiles
ln -sf "$DEV_HOME/dotfile/.gitconfig" "$DEV_HOME/.gitconfig"
ln -sf "$DEV_HOME/dotfile/.npmrc" "$DEV_HOME/.npmrc"

chown -R dev:dev "$DEV_HOME"

# ============================================================
# PHASE 3: Dev user — config, settings, session sync
# ============================================================

echo "--- Switching to dev user ---"

su - dev << 'DEVSETUP'
set -eo pipefail

echo "--- Claude Code config ---"
mkdir -p ~/.claude
if [ ! -f ~/.claude/settings.json ]; then
  cat > ~/.claude/settings.json << 'SETTINGS'
{
  "skipDangerousModePermissionPrompt": true
}
SETTINGS
  echo "Claude Code: settings configured"
else
  echo "Claude Code: settings.json already exists, skipping"
fi

echo "--- Session sync ---"
if [ ! -d ~/claude-sessions ]; then
  git clone git@github.com:qwadratic/claude-sessions.git ~/claude-sessions 2>/dev/null || \
    echo "Could not clone claude-sessions — set up SSH key for GitHub first"
fi
if ! pm2 list 2>/dev/null | grep -q "session-sync"; then
  pm2 start ~/dotfile/sync-sessions.sh --name session-sync --cron-restart="0 */4 * * *" --no-autorestart --interpreter bash 2>/dev/null || true
  pm2 save 2>/dev/null || true
  echo "Session sync: pm2 cron installed (every 4 hours)"
else
  echo "Session sync: pm2 cron already configured"
fi

echo ""
echo "=== Install complete ==="
DEVSETUP
