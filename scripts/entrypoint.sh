#!/bin/bash
# =============================================================================
# ai-dev-sandbox — Inner Container Entrypoint
# =============================================================================
# Runs inside the Firecracker guest VM's Docker container (ai-dev-sandbox:latest).
# This is what the developer interacts with.
#
# On first run:
#   - Sets up home directory structure
#   - Installs AI CLI tools (cached in home volume after first run)
#   - Checks voice mode (gracefully skipped if no audio)
#   - Tests Ollama connectivity
#
# Subsequent runs (home volume persists):
#   - Skips installation (tools already installed)
#   - Prints the welcome banner
#   - Drops into bash (or runs the provided command)
# =============================================================================

set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
    echo "Refusing to run as root. Use the sandbox user." >&2
    exit 1
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC}   $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERR]${NC}  $1" >&2; }

# =============================================================================
# Home directory setup
# =============================================================================
setup_home() {
    log_info "Setting up home directory..."

    mkdir -p \
        ~/.config ~/.cache \
        ~/.local/bin \
        ~/.npm-global/bin \
        ~/go/bin ~/go/pkg ~/go/src \
        ~/.cargo/bin

    # SSH keys (bind-mounted from host as read-only .ssh.host)
    if [ -d ~/.ssh.host ]; then
        mkdir -p ~/.ssh
        cp -n ~/.ssh.host/* ~/.ssh/ 2>/dev/null || true
        chmod 700 ~/.ssh
        chmod 600 ~/.ssh/* 2>/dev/null || true
        log_success "SSH keys configured"
    fi

    # Git config (bind-mounted as .gitconfig.host)
    if [ -f ~/.gitconfig.host ]; then
        cp -n ~/.gitconfig.host ~/.gitconfig 2>/dev/null || true
        log_success "Git config configured"
    fi

    # npm global prefix → home dir (no sudo needed, survives home volume)
    npm config set prefix '/home/sandbox/.npm-global' 2>/dev/null || true
}

# =============================================================================
# AI CLI tool installers
# Each is idempotent — checks for the binary first.
# All run in parallel on first boot (see main()).
# After the first run ~/.sandbox_initialized persists in the home volume,
# so subsequent container starts skip this entirely.
# =============================================================================

install_claude_code() {
    if command -v claude &>/dev/null; then
        log_success "Claude Code: $(claude --version 2>/dev/null | head -1 || echo 'installed')"
        return 0
    fi
    log_info "Installing Claude Code (@anthropic-ai/claude-code)..."
    if npm install -g @anthropic-ai/claude-code 2>/tmp/claude-install.log; then
        log_success "Claude Code installed"
    else
        log_warn "Claude Code install failed (check /tmp/claude-install.log)"
    fi
}

install_opencode() {
    if command -v opencode &>/dev/null; then
        log_success "OpenCode: $(opencode --version 2>/dev/null | head -1 || echo 'installed')"
        return 0
    fi
    log_info "Installing OpenCode (opencode.ai)..."
    if curl -fsSL https://opencode.ai/install | bash 2>/tmp/opencode-install.log; then
        log_success "OpenCode installed"
    else
        log_warn "OpenCode install failed (check /tmp/opencode-install.log)"
    fi
}

install_chatgpt_cli() {
    if command -v chatgpt &>/dev/null; then
        log_success "ChatGPT CLI: installed"
        return 0
    fi
    log_info "Installing ChatGPT CLI (go install)..."
    if go install github.com/kardolus/chatgpt-cli/cmd/chatgpt@latest 2>/tmp/chatgpt-install.log; then
        log_success "ChatGPT CLI installed"
    else
        log_warn "ChatGPT CLI install failed (check /tmp/chatgpt-install.log)"
    fi
}

install_gemini_cli() {
    if command -v gemini &>/dev/null; then
        log_success "Gemini CLI: installed"
        return 0
    fi
    log_info "Installing Gemini CLI (@google/gemini-cli)..."
    if npm install -g @google/gemini-cli 2>/tmp/gemini-install.log; then
        log_success "Gemini CLI installed"
    else
        log_warn "Gemini CLI install failed (check /tmp/gemini-install.log)"
    fi
}

# =============================================================================
# Voice mode — gracefully optional
# If PulseAudio is not available, scripts still exist but warn on use.
# =============================================================================
setup_voice_mode() {
    # Ensure scripts are linked (they live in /opt/scripts, linked to ~/.local/bin)
    ln -sf /opt/scripts/stt   ~/.local/bin/stt   2>/dev/null || true
    ln -sf /opt/scripts/tts   ~/.local/bin/tts   2>/dev/null || true
    ln -sf /opt/scripts/voice ~/.local/bin/voice 2>/dev/null || true

    if pactl info &>/dev/null 2>&1; then
        log_success "Voice mode: PulseAudio connected (stt / tts / voice ready)"
    else
        log_warn "Voice mode: no audio detected — stt/tts/voice will be skipped gracefully"
        log_warn "  To enable: mount a PulseAudio socket into the guest VM"
    fi
}

# =============================================================================
# Ollama connectivity check
# =============================================================================
check_ollama() {
    local host="${OLLAMA_HOST:-}"
    [ -z "$host" ] && return 0

    if curl -sf --max-time 3 "$host/api/tags" >/dev/null 2>&1; then
        local models
        models=$(curl -sf --max-time 3 "$host/api/tags" \
            | jq -r '.models[].name' 2>/dev/null | head -3 | tr '\n' ' ' || echo '?')
        log_success "Ollama: connected at $host  ($models)"
    else
        log_warn "OPTIONAL - Ollama: cannot reach $host - install on host or cloud."
    fi
}

# =============================================================================
# Welcome banner
# =============================================================================
print_banner() {
   ~/.local/bin/banner.sh
}

# =============================================================================
# Main initialization (first run only)
# =============================================================================
main() {
    log_info "Initializing AI Sandbox (first run)..."

    setup_home

    # Install AI CLIs in parallel — each writes its own log to /tmp/
    install_claude_code  &
    install_opencode     &
    install_chatgpt_cli  &
    install_gemini_cli   &
    wait

    setup_voice_mode
    check_ollama

    touch ~/.sandbox_initialized
    log_success "Initialization complete"
}

# ─── Run init on first start only (marker persists in home volume) ────────────
if [ ! -f ~/.sandbox_initialized ]; then
    main
fi

cd /workspace 2>/dev/null || true
source ~/.bashrc 2>/dev/null || true
print_banner

# ─── Execute requested command or drop into bash ─────────────────────────────
if [ $# -gt 0 ]; then
    exec "$@"
else
    exec /bin/bash
fi
