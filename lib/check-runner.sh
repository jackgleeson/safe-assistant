#!/usr/bin/env bash
# Helpers for claude-runner restricted user

RUNNER_USER="claude-runner"

check_runner_exists() {
    if ! id "$RUNNER_USER" &>/dev/null; then
        fail "User '$RUNNER_USER' does not exist. Run bin/setup-claude-runner first."
    fi
}

check_project_access() {
    local dir="${1:-$PWD}"

    if ! sudo -u "$RUNNER_USER" test -r "$dir"; then
        fail "$RUNNER_USER cannot read $dir. Check group permissions (chmod g+rwx)."
    fi

    if ! sudo -u "$RUNNER_USER" test -w "$dir"; then
        warn "$RUNNER_USER cannot write to $dir. Claude may not be able to edit files."
        warn "  Fix: chmod g+rwx $dir"
    fi
}
