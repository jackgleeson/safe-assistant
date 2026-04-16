#!/usr/bin/env bash
# Platform detection - sets SAFE_ASSISTANT_OS to "linux" or "macos",
# plus RUNNER_USER and RUNNER_HOME_BASE for the claude-runner isolation flow.

detect_platform() {
    local kernel
    kernel="$(uname -s)"

    case "$kernel" in
        Linux)  SAFE_ASSISTANT_OS="linux" ;;
        Darwin) SAFE_ASSISTANT_OS="macos" ;;
        *)
            warn "Unsupported platform: $kernel - checks will be skipped"
            SAFE_ASSISTANT_OS="unknown"
            ;;
    esac

    if [[ "$SAFE_ASSISTANT_OS" == "macos" ]]; then
        # macOS system-user convention: leading underscore.
        RUNNER_USER="${RUNNER_USER:-_claude-runner}"
        RUNNER_HOME_BASE="${RUNNER_HOME_BASE:-/Users}"
    else
        RUNNER_USER="${RUNNER_USER:-claude-runner}"
        RUNNER_HOME_BASE="${RUNNER_HOME_BASE:-/home}"
    fi

    export SAFE_ASSISTANT_OS RUNNER_USER RUNNER_HOME_BASE
}

warn() {
    printf '\033[33m[safe-assistant] ⚠\033[0m %s\n' "$1" >&2
}

fail() {
    printf '\033[31m[safe-assistant] ✗\033[0m %s\n' "$1" >&2
    exit 1
}

info() {
    printf '\033[36m[safe-assistant] ℹ\033[0m %s\n' "$1" >&2
}

ok() {
    if [[ $# -gt 1 ]]; then
        printf '\033[32m[safe-assistant] ✓\033[0m %s \033[38;5;248m- %s\033[0m\n' "$1" "$2" >&2
    else
        printf '\033[32m[safe-assistant] ✓\033[0m %s\n' "$1" >&2
    fi
}
