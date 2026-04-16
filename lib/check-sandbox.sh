#!/usr/bin/env bash
# Verify sandbox dependencies are installed (Claude Code specific)

# Verify sandbox.enabled is true in the settings.json Claude will actually read.
# Args:
#   $1 strict      - "true" to fail instead of warn
#   $2 settings    - path to settings.json (default: $HOME/.claude/settings.json)
#   $3 sudo_as     - optional user to read the file as (for the runner's home)
check_sandbox_enabled() {
    local strict="${1:-false}"
    local settings="${2:-$HOME/.claude/settings.json}"
    local sudo_as="${3:-}"

    local reader=(cat)
    [[ -n "$sudo_as" ]] && reader=(sudo -n -u "$sudo_as" cat)

    if ! "${reader[@]}" "$settings" &>/dev/null; then
        warn "cannot read $settings to check sandbox.enabled"
        [[ "$strict" == "true" ]] && fail "sandbox.enabled check failed in strict mode"
        return
    fi

    if ! command -v jq &>/dev/null; then
        warn "jq not installed - skipping sandbox.enabled check"
        return
    fi

    local enabled
    enabled=$("${reader[@]}" "$settings" 2>/dev/null | jq -r '.sandbox.enabled // false')
    if [[ "$enabled" == "true" ]]; then
        ok "sandbox.enabled: true in $settings"
    else
        warn "sandbox.enabled is not true in $settings - Claude's bash sandbox is OFF"
        if [[ -n "$sudo_as" ]]; then
            warn "  Fix: bin/setup-claude-runner (re-syncs the runner's settings)"
        else
            warn "  Fix: run bin/sync-deny-paths"
        fi
        [[ "$strict" == "true" ]] && fail "sandbox.enabled check failed in strict mode"
    fi
}

check_sandbox_deps() {
    local strict="${1:-false}"
    local problems=0

    # ripgrep - needed on all platforms
    if command -v rg &>/dev/null; then
        ok "ripgrep (rg) found" "fast code search inside the sandbox"
    else
        warn "ripgrep (rg) not found - used by Claude Code for fast search"
        ((problems++)) || true
    fi

    if [[ "${SAFE_ASSISTANT_OS:-unknown}" == "linux" ]]; then
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
        ok "bubblewrap (bwrap) found" "filesystem namespace for the sandbox"
    else
        warn "bubblewrap (bwrap) not found - sandbox will not work"
        warn "  Fix: sudo apt install bubblewrap"
        ((problems++)) || true
    fi

    # socat
    if command -v socat &>/dev/null; then
        ok "socat found" "proxies stdio across the sandbox boundary"
    else
        warn "socat not found - sandbox networking may not work"
        warn "  Fix: sudo apt install socat"
        ((problems++)) || true
    fi

    # seccomp filter
    if npm ls -g @anthropic-ai/sandbox-runtime &>/dev/null 2>&1; then
        ok "seccomp filter (@anthropic-ai/sandbox-runtime) found" "blocks unix socket access from the sandbox"
    else
        warn "seccomp filter not installed - sandbox cannot block unix socket access"
        warn "  Fix: npm install -g @anthropic-ai/sandbox-runtime"
        ((problems++)) || true
    fi

    return "$problems"
}
