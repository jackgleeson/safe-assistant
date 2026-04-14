#!/usr/bin/env bash
# Platform detection - sets LLM_SAFE_OS to "linux" or "macos"

detect_platform() {
    local kernel
    kernel="$(uname -s)"

    case "$kernel" in
        Linux)  LLM_SAFE_OS="linux" ;;
        Darwin) LLM_SAFE_OS="macos" ;;
        *)
            warn "Unsupported platform: $kernel - checks will be skipped"
            LLM_SAFE_OS="unknown"
            ;;
    esac

    export LLM_SAFE_OS
}

warn() {
    printf '\033[33m[llm-safe]\033[0m %s\n' "$1" >&2
}

fail() {
    printf '\033[31m[llm-safe]\033[0m %s\n' "$1" >&2
    exit 1
}

info() {
    printf '\033[36m[llm-safe]\033[0m %s\n' "$1" >&2
}

ok() {
    printf '\033[32m[llm-safe]\033[0m %s\n' "$1" >&2
}
