#!/bin/bash
set -euo pipefail

# Interactive wizard to create and provision a staging VM on exe.dev.
# Usage: bash setup-staging-vm.sh
# Requires: gh CLI authenticated, .env.staging in current directory

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[..] $1${NC}"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; }
ask()  { echo -en "${YELLOW}$1${NC}"; read -r REPLY; }

echo ""
echo "=== Staging VM Setup Wizard ==="
echo ""

# --- Pre-checks ---
if [ ! -f .env.staging ]; then
  fail ".env.staging not found in current directory"
  exit 1
fi

if ! gh auth status &>/dev/null; then
  fail "gh CLI not authenticated. Run 'gh auth login' first"
  exit 1
fi

# --- Step 1: VM slug ---
ask "VM name slug (e.g. ortobor-staging): "
VM_SLUG="$REPLY"
if [ -z "$VM_SLUG" ]; then
  fail "VM slug cannot be empty"
  exit 1
fi
VM_HOST="${VM_SLUG}.exe.xyz"

# --- Step 2: GitHub repo ---
ask "GitHub repo (e.g. qwadratic/ortobor-academy): "
GH_REPO="$REPLY"
if [ -z "$GH_REPO" ]; then
  fail "GitHub repo cannot be empty"
  exit 1
fi
echo ""

# --- Step 3: Create VM ---
warn "Creating VM '$VM_SLUG' on exe.dev (node:22 image)..."
RESULT=$(ssh exe.dev new --name="$VM_SLUG" --image=node:22 --json 2>&1) || {
  fail "VM creation failed: $RESULT"
  exit 1
}
ok "VM created: $VM_HOST"
echo ""

# --- Step 4: Accept host key ---
warn "Testing SSH connection..."
ssh -o StrictHostKeyChecking=accept-new "$VM_HOST" echo "connected" 2>/dev/null || {
  fail "Cannot SSH to $VM_HOST"
  exit 1
}
ok "SSH connected"
echo ""

# --- Step 5: Install base tools ---
warn "Installing base tools (pnpm, pm2, Caddy)... ~1 minute"
ssh "$VM_HOST" bash -s << 'SETUP'
set -euo pipefail

apt-get update -qq
apt-get install -y -qq zsh git curl jq 2>/dev/null

# pnpm
corepack enable 2>/dev/null || { npm install -g corepack && corepack enable; }
COREPACK_ENABLE_AUTO_PIN=0 corepack prepare pnpm@latest --activate

# pm2 + log rotation
npm install -g pm2 2>&1 | tail -1
pm2 install pm2-logrotate 2>&1 | tail -1
pm2 set pm2-logrotate:max_size 50M
pm2 set pm2-logrotate:retain 7
pm2 set pm2-logrotate:dateFormat YYYY-MM-DD
pm2 set pm2-logrotate:rotateInterval '0 0 * * *'

# Caddy
apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https 2>/dev/null
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg 2>/dev/null
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list > /dev/null
apt-get update -qq && apt-get install -y -qq caddy

# Caddyfile — exe.dev handles TLS, Caddy serves HTTP only
mkdir -p /var/log/caddy
cat > /etc/caddy/Caddyfile << 'CADDY'
:80 {
    reverse_proxy localhost:3000
    log {
        output file /var/log/caddy/access.log {
            roll_size 50mb
            roll_keep 7
            roll_keep_for 168h
        }
    }
}
CADDY

# Start Caddy via pm2
pm2 start caddy --name caddy -- run --config /etc/caddy/Caddyfile
pm2 save

# Git config
git config --global user.name "qwadratic"
git config --global user.email "qwadratic@builds.dev"

echo "TOOLS_DONE"
SETUP
ok "Base tools installed"
echo ""

# --- Step 6: Make port public ---
warn "Making port 80 public..."
ssh exe.dev share set-public "$VM_SLUG" 2>&1
ok "Port 80 is public"
echo ""

# --- Step 7: Copy env vars ---
warn "Copying .env.staging to VM..."
scp -q .env.staging "$VM_HOST":~/app.env
ssh "$VM_HOST" "sed -i 's/STAGING_VM/${VM_SLUG}/g' ~/app.env"
ok "Env vars configured"
echo ""

# --- Step 8: GitHub Actions runner ---
echo "--- GitHub Actions Runner ---"
ask "Set up GH Actions runner? [Y/n]: "
if [[ ! "$REPLY" =~ ^[Nn] ]]; then
  warn "Getting runner registration token..."
  TOKEN=$(gh api -X POST "repos/${GH_REPO}/actions/runners/registration-token" --jq '.token' 2>&1)
  if [ -z "$TOKEN" ] || echo "$TOKEN" | grep -q "error"; then
    fail "Could not get runner token: $TOKEN"
    warn "Set up runner manually later — see DEPLOY.md"
  else
    ok "Got token"
    warn "Installing runner on VM..."
    ssh "$VM_HOST" bash -s << RUNNER
set -euo pipefail
mkdir -p ~/actions-runner && cd ~/actions-runner
RUNNER_VERSION="2.322.0"
curl -fsSL "https://github.com/actions/runner/releases/download/v\${RUNNER_VERSION}/actions-runner-linux-x64-\${RUNNER_VERSION}.tar.gz" -o runner.tar.gz
tar xzf runner.tar.gz && rm runner.tar.gz
./bin/installdependencies.sh 2>&1 | tail -3
RUNNER_ALLOW_RUNASROOT=1 ./config.sh \\
  --url "https://github.com/${GH_REPO}" \\
  --token "${TOKEN}" \\
  --labels staging \\
  --name "${VM_SLUG}" \\
  --unattended --replace
RUNNER_ALLOW_RUNASROOT=1 pm2 start run.sh --name gh-runner --cwd ~/actions-runner --interpreter bash
pm2 save
RUNNER
    ok "Runner installed and running"
  fi
else
  warn "Skipped — see DEPLOY.md for manual setup"
fi
echo ""

# --- Step 9: Supabase migrations ---
echo "--- Supabase ---"
ask "Push Supabase migrations now? (requires supabase CLI linked) [y/N]: "
if [[ "$REPLY" =~ ^[Yy] ]]; then
  supabase db push 2>&1 || warn "Migration push failed — do it manually"
else
  warn "Skipped — run 'supabase db push' when ready"
fi
echo ""

# --- Final status ---
echo ""
echo "=== Final verification ==="
ssh "$VM_HOST" bash -s << 'CHECK'
echo "Node:     $(node --version)"
echo "pnpm:     $(pnpm --version)"
echo "pm2:      $(pm2 --version)"
echo "caddy:    $(caddy version 2>/dev/null)"
echo "Disk:     $(df -h / | tail -1 | awk '{print $4 " free"}')"
echo ""
echo "Processes:"
pm2 ls --no-color 2>/dev/null | grep -E 'name|caddy|gh-runner|academy' || pm2 ls
CHECK

echo ""
echo "=== Staging VM ready ==="
echo ""
echo "  URL:      https://${VM_HOST}"
echo "  SSH:      ssh ${VM_HOST}"
echo "  Logs:     ssh ${VM_HOST} pm2 logs academy"
echo "  Deploy:   push to main → auto-deploys via GH Actions"
echo ""
