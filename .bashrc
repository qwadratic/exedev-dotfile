# --- Secrets (not in repo) ---
[ -f ~/.env.secrets ] && source ~/.env.secrets

# --- PATH ---
export PATH="$HOME/.local/bin:$PATH"
export PNPM_HOME="$HOME/.local/share/pnpm"
export PATH="$PNPM_HOME:$PATH"

# --- fnm (node version manager) ---
eval "$(fnm env --use-on-cd 2>/dev/null)" || true

# --- Auto-switch to dev user on exe.dev VMs (sshd forces root) ---
if [ "$(whoami)" = "root" ] && [ -d /exe.dev ] && [ -n "$SSH_CONNECTION" ] && [[ $- == *i* ]]; then
  exec su - dev
fi

# --- Aliases ---
alias yolo="CLAUDE_CODE_NO_FLICKER=1 claude --dangerously-skip-permissions"
alias ll='ls -la'
alias gs='git status'
alias gd='git diff'
alias gl='git log --oneline -20'

# --- Prompt ---
PS1='\[\e[36m\]\w\[\e[0m\] \[\e[32m\]$(git branch --show-current 2>/dev/null)\[\e[0m\] $ '
