# =============================================================================
# Welcome banner
# =============================================================================

    echo ""
    echo -e "${BLUE}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC}  ${GREEN}AI Development Sandbox${NC} v${SANDBOX_VERSION:-1.0.0}                                 ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}  Firecracker MicroVM → Guest Docker → You                      ${BLUE}║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    echo -e "  ${YELLOW}Current User:${NC}"
    command id
    echo ""

    echo -e "  ${YELLOW}AI Tools:${NC}"
    command -v claude    &>/dev/null && echo "    ✓ claude     (Claude Code)" || echo "    ✗ claude     (not installed)"
    command -v opencode  &>/dev/null && echo "    ✓ opencode   (OpenCode)"    || echo "    ✗ opencode   (not installed)"
    command -v chatgpt   &>/dev/null && echo "    ✓ chatgpt    (ChatGPT CLI)" || echo "    ✗ chatgpt    (not installed)"
    command -v gemini    &>/dev/null && echo "    ✓ gemini     (Gemini CLI)"  || echo "    ✗ gemini     (not installed)"
    echo ""

    echo -e "  ${YELLOW}Languages:${NC}"
    command -v go      &>/dev/null && echo "    ✓ $(go version 2>/dev/null | awk '{print $1, $3}')"
    command -v python3 &>/dev/null && echo "    ✓ python $(python3 --version 2>/dev/null | awk '{print $2}')"
    command -v rustc   &>/dev/null && echo "    ✓ $(rustc --version 2>/dev/null | awk '{print $1, $2}')"
    command -v node    &>/dev/null && echo "    ✓ node $(node --version 2>/dev/null)"
    echo ""

    echo -e "  ${YELLOW}Source Control:${NC}"
    command -v gh        &>/dev/null && echo "    ✓ gh         (GitHub CLI)"  || echo "    ✗ gh         (not installed)"
    command -v git       &>/dev/null && echo "    ✓ git        (Git)"         || echo "    ✗ git        (not installed)"
    echo ""

    echo -e "  ${YELLOW}Voice:${NC}"
    if pactl info &>/dev/null 2>&1; then
        echo "    ✓ stt / tts / voice  (PulseAudio connected)"
    else
        echo "    ✗ stt / tts / voice  (no audio — gracefully skipped)"
    fi
    echo ""

    echo -e "  ${YELLOW}Workspace:${NC} /workspace"
    [ -n "${OLLAMA_HOST:-}" ] && echo -e "  ${YELLOW}Ollama:${NC}    ${OLLAMA_HOST}"
    echo ""

    echo -e "  ${YELLOW}Quick Start:${NC}"
    echo "    claude               # Start Claude Code"
    echo "    opencode             # Start OpenCode"
    echo "    gemini               # Start Gemini CLI"
    echo "    voice ai-tool-name   # Voice chat (if audio available)"
    echo ""
