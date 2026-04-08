#!/bin/bash
set -euo pipefail

# Non-interactive install script for dev VM tools.
# Called by setup-dev-vm.sh after VM creation.
# Can also be run standalone on an existing VM.

DOTFILE_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Dev VM Bootstrap ==="

# 1. System packages
echo "--- System packages ---"
apt-get update -qq
apt-get install -y -qq git curl jq rsync 2>/dev/null

# 2. corepack + pnpm (node already present on node:22 image)
echo "--- corepack + pnpm ---"
corepack enable 2>/dev/null || npm install -g corepack && corepack enable
COREPACK_ENABLE_AUTO_PIN=0 corepack prepare pnpm@latest --activate
echo "Node: $(node --version)"
echo "pnpm: $(pnpm --version)"

# 3. gh CLI
echo "--- gh CLI ---"
if ! command -v gh &>/dev/null; then
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg 2>/dev/null
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null
  apt-get update -qq && apt-get install -y -qq gh
fi
echo "gh: $(gh --version | head -1)"

# 4. Claude Code
echo "--- Claude Code ---"
if ! command -v claude &>/dev/null; then
  npm install -g @anthropic-ai/claude-code
fi
echo "claude: $(claude --version 2>/dev/null || echo 'installed')"

# 5. Supabase CLI (binary, npm global doesn't work)
echo "--- Supabase CLI ---"
if ! command -v supabase &>/dev/null; then
  ARCH=$(dpkg --print-architecture)
  # Try fetching latest version, fall back to known good
  SB_VERSION=$(curl -sf https://api.github.com/repos/supabase/cli/releases/latest | jq -r '.tag_name // empty' | sed 's/^v//' 2>/dev/null || echo "")
  [ -z "$SB_VERSION" ] && SB_VERSION="2.20.12"
  echo "Installing supabase v${SB_VERSION}"
  curl -fsSL "https://github.com/supabase/cli/releases/download/v${SB_VERSION}/supabase_linux_${ARCH}.tar.gz" -o /tmp/supabase.tar.gz
  tar -xzf /tmp/supabase.tar.gz -C /usr/local/bin supabase
  rm /tmp/supabase.tar.gz
fi
echo "supabase: $(supabase --version 2>/dev/null)"

# 6. Vercel CLI
echo "--- Vercel CLI ---"
if ! command -v vercel &>/dev/null; then
  npm install -g vercel
fi
echo "vercel: $(vercel --version 2>/dev/null | head -1)"

# 7. pm2
echo "--- pm2 ---"
if ! command -v pm2 &>/dev/null; then
  npm install -g pm2
fi
echo "pm2: $(pm2 --version 2>/dev/null)"

# 8. Symlink dotfiles
echo "--- Dotfiles ---"
ln -sf "$DOTFILE_DIR/.gitconfig" ~/.gitconfig
ln -sf "$DOTFILE_DIR/.npmrc" ~/.npmrc

# Source dotfile .bashrc
if ! grep -q "dotfile/.bashrc" ~/.bashrc 2>/dev/null; then
  echo '[ -f ~/dotfile/.bashrc ] && source ~/dotfile/.bashrc' >> ~/.bashrc
fi

# 9. Claude Code settings — disable noisy MCPs
echo "--- Claude Code config ---"
mkdir -p ~/.claude
if [ ! -f ~/.claude/settings.json ]; then
  cat > ~/.claude/settings.json << 'SETTINGS'
{
  "disabledMcpjsonServers": [
    "chrome-devtools",
    "claude-ai-stripe",
    "claude-ai-Figma",
    "claude-ai-Gmail",
    "claude-ai-Google Calendar",
    "claude-ai-Google Drive",
    "claude-ai-Notion",
    "claude-ai-Slack"
  ],
  "skipDangerousModePermissionPrompt": true
}
SETTINGS
  echo "Claude Code: disabled noisy MCPs"
else
  echo "Claude Code: settings.json already exists, skipping"
fi

# 10. Session sync — clone repo + set up cron
echo "--- Session sync ---"
if [ ! -d ~/claude-sessions ]; then
  git clone git@github.com:qwadratic/claude-sessions.git ~/claude-sessions 2>/dev/null || \
    echo "Could not clone claude-sessions — set up SSH key for GitHub first"
fi
# Schedule via pm2 cron (no crontab on exe.dev VMs)
if ! pm2 list 2>/dev/null | grep -q "session-sync"; then
  pm2 start "$DOTFILE_DIR/sync-sessions.sh" --name session-sync --cron-restart="0 */4 * * *" --no-autorestart --interpreter bash 2>/dev/null
  pm2 save 2>/dev/null
  echo "Session sync: pm2 cron installed (every 4 hours)"
else
  echo "Session sync: pm2 cron already configured"
fi

# 11. Provision non-root user (dev) for Claude Code yolo mode
# Claude Code refuses --dangerously-skip-permissions as root
echo "--- Non-root user (dev) ---"
DEV_HOME="/home/dev"
if id dev &>/dev/null; then
  echo "dev user exists"
else
  useradd -m -s /bin/bash dev
  echo "dev user created"
fi

# Copy dotfile repo
if [ ! -d "$DEV_HOME/dotfile" ]; then
  cp -r "$DOTFILE_DIR" "$DEV_HOME/dotfile"
fi

# Source dotfile .bashrc
if ! grep -q "dotfile/.bashrc" "$DEV_HOME/.bashrc" 2>/dev/null; then
  echo '[ -f ~/dotfile/.bashrc ] && source ~/dotfile/.bashrc' >> "$DEV_HOME/.bashrc"
fi

# Symlink dotfiles
ln -sf "$DEV_HOME/dotfile/.gitconfig" "$DEV_HOME/.gitconfig"
ln -sf "$DEV_HOME/dotfile/.npmrc" "$DEV_HOME/.npmrc"

# Claude Code settings
mkdir -p "$DEV_HOME/.claude"
if [ ! -f "$DEV_HOME/.claude/settings.json" ]; then
  cp ~/.claude/settings.json "$DEV_HOME/.claude/settings.json" 2>/dev/null || true
  echo "Claude Code: copied settings to dev user"
fi

# Copy SSH keys from root so gh/git work
mkdir -p "$DEV_HOME/.ssh"
if [ -f ~/.ssh/id_ed25519 ]; then
  cp ~/.ssh/id_ed25519 "$DEV_HOME/.ssh/"
  cp ~/.ssh/id_ed25519.pub "$DEV_HOME/.ssh/" 2>/dev/null || true
  chmod 600 "$DEV_HOME/.ssh/id_ed25519"
fi
cp ~/.ssh/known_hosts "$DEV_HOME/.ssh/" 2>/dev/null || true

# Copy git credentials
cp ~/.git-credentials "$DEV_HOME/.git-credentials" 2>/dev/null || true

# Fix ownership
chown -R dev:dev "$DEV_HOME"

# Auto-switch root to dev user on interactive SSH
if ! grep -q "exec su - dev" ~/.profile 2>/dev/null; then
  sed -i '1a\# Auto-switch to dev user (Claude Code needs non-root for yolo mode)\nif [ "$(whoami)" = "root" ] \&\& [ -d /exe.dev ] \&\& [ -n "$SSH_CONNECTION" ] \&\& [ -t 0 ]; then exec su - dev; fi\n' ~/.profile
fi

echo "dev user provisioned"

echo ""
echo "=== Install complete ==="
