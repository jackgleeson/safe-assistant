#!/usr/bin/env bash
# Verify OS-level hardening settings

check_hardening() {
    local strict="${1:-false}"
    local problems=0

    if [[ "${SAFE_ASSISTANT_OS:-unknown}" == "linux" ]]; then
        _check_ptrace_scope "$strict" || ((problems++)) || true
    elif [[ "${SAFE_ASSISTANT_OS:-unknown}" == "macos" ]]; then
        _check_sip "$strict" || ((problems++)) || true
    fi

    _check_ssh_agent_loaded || true

    if [[ "$problems" -gt 0 && "$strict" == "true" ]]; then
        fail "Pre-flight checks failed in strict mode ($problems problem(s))"
    fi
}

_check_ptrace_scope() {
    local strict="$1"
    local scope

    if [[ ! -f /proc/sys/kernel/yama/ptrace_scope ]]; then
        warn "Cannot read ptrace_scope - Yama LSM may not be enabled"
        return 1
    fi

    scope=$(cat /proc/sys/kernel/yama/ptrace_scope)

    case "$scope" in
        0)
            local msg="ptrace_scope is 0 - any process owned by your user can read ssh-agent memory"
            if [[ "$strict" == "true" ]]; then
                fail "$msg. Fix: echo 1 | sudo tee /proc/sys/kernel/yama/ptrace_scope"
            else
                warn "$msg"
                warn "  Fix: echo 1 | sudo tee /proc/sys/kernel/yama/ptrace_scope"
            fi
            return 1
            ;;
        1) ok "ptrace_scope = 1 (parent-only)" ;;
        2) ok "ptrace_scope = 2 (admin-only)" ;;
        3) ok "ptrace_scope = 3 (no ptrace)" ;;
        *) warn "ptrace_scope = $scope (unrecognized value)" ;;
    esac
    return 0
}

_check_sip() {
    local strict="$1"

    if ! command -v csrutil &>/dev/null; then
        warn "csrutil not found - cannot verify SIP status"
        return 1
    fi

    local status
    status=$(csrutil status 2>&1)

    if echo "$status" | grep -q "enabled"; then
        ok "System Integrity Protection is enabled"
        return 0
    else
        local msg="SIP is not enabled - process tracing protections are reduced"
        if [[ "$strict" == "true" ]]; then
            fail "$msg"
        else
            warn "$msg"
        fi
        return 1
    fi
}

_check_ssh_agent_loaded() {
    if [[ -n "${SSH_AUTH_SOCK:-}" ]]; then
        local key_count
        key_count=$(ssh-add -l 2>/dev/null | grep -cv "^The agent has no" || true)
        if [[ "$key_count" -gt 0 ]]; then
            info "SSH agent has $key_count key(s) loaded - these will be inaccessible to the assistant"
        fi
    fi
}
