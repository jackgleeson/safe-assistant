#!/usr/bin/env bash
# Verify sandbox dependencies are installed (Claude Code specific)

check_sandbox_deps() {
    local strict="${1:-false}"
    local problems=0

    # ripgrep - needed on all platforms
    if command -v rg &>/dev/null; then
        ok "ripgrep (rg) found"
    else
        warn "ripgrep (rg) not found - used by Claude Code for fast search"
        ((problems++)) || true
    fi

    if [[ "${LLM_SAFE_OS:-unknown}" == "linux" ]]; then
        _check_linux_deps || ((problems += $?)) || true
    fi

    # macOS uses built-in sandbox-exec, no extra deps needed

    if [[ "$problems" -gt 0 ]]; then
        warn "$problems sandbox dependency problem(s) found"
        if [[ "$strict" == "true" ]]; then
            fail "Sandbox checks failed in strict mode"
        fi
    fi
}

_check_linux_deps() {
    local problems=0

    # bubblewrap
    if command -v bwrap &>/dev/null; then
        ok "bubblewrap (bwrap) found"
    else
        warn "bubblewrap (bwrap) not found - sandbox will not work"
        warn "  Fix: sudo apt install bubblewrap"
        ((problems++)) || true
    fi

    # socat
    if command -v socat &>/dev/null; then
        ok "socat found"
    else
        warn "socat not found - sandbox networking may not work"
        warn "  Fix: sudo apt install socat"
        ((problems++)) || true
    fi

    # seccomp filter
    if npm ls -g @anthropic-ai/sandbox-runtime &>/dev/null 2>&1; then
        ok "seccomp filter (@anthropic-ai/sandbox-runtime) found"
    else
        warn "seccomp filter not installed - sandbox cannot block unix socket access"
        warn "  Fix: npm install -g @anthropic-ai/sandbox-runtime"
        ((problems++)) || true
    fi

    return "$problems"
}
