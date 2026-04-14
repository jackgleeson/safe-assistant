#!/usr/bin/env bash
# Platform detection - sets SAFE_ASSISTANT_OS to "linux" or "macos"

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

    export SAFE_ASSISTANT_OS
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
    printf '\033[32m[safe-assistant] ✓\033[0m %s\n' "$1" >&2
}
