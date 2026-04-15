#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$SCRIPT_DIR/bin"
LIB_DIR="$SCRIPT_DIR/lib"

source "$LIB_DIR/check-platform.sh"
source "$LIB_DIR/check-hardening.sh"
source "$LIB_DIR/check-sandbox.sh"

# --- Options ---

DRY_RUN=false

case "${1:-}" in
    --dry-run) DRY_RUN=true ;;
    -h|--help)
        echo "Usage: install.sh [--dry-run]"
        echo ""
        echo "Options:"
        echo "  --dry-run  Show what would be done without making changes"
        echo "  -h, --help Show this help message"
        exit 0
        ;;
    "") ;;
    *) echo "Unknown option: $1"; exit 1 ;;
esac

# --- Helpers ---

prompt_yn() {
    local question="$1" default="${2:-n}"

    if [[ "$DRY_RUN" == "true" ]]; then
        # In dry-run mode, show the prompt but auto-answer yes to show all actions
        echo "$question [dry-run: yes]"
        return 0
    fi

    local yn
    if [[ "$default" == "y" ]]; then
        read -rp "$question [Y/n] " yn
        yn="${yn:-y}"
    else
        read -rp "$question [y/N] " yn
        yn="${yn:-n}"
    fi
    [[ "$yn" =~ ^[Yy] ]]
}

dry_run_skip() {
    if [[ "$DRY_RUN" == "true" ]]; then
        info "[dry-run] Would: $1"
        return 0
    fi
    return 1
}

# --- Main ---

echo ""
if [[ "$DRY_RUN" == "true" ]]; then
    echo "safe-assistant installer (dry run)"
    echo "============================"
else
    echo "safe-assistant installer"
    echo "=================="
fi
echo ""

# 1. Platform detection and checks (read-only, safe in dry-run)
detect_platform
echo ""
echo "--- System hardening checks (read-only) ---"
echo ""
check_hardening false
echo ""
echo "--- Sandbox dependency checks (read-only) ---"
echo ""
check_sandbox_deps false
echo ""

# 2. Install missing Linux dependencies
if [[ "$SAFE_ASSISTANT_OS" == "linux" ]]; then
    missing=()
    command -v bwrap &>/dev/null || missing+=(bubblewrap)
    command -v socat &>/dev/null || missing+=(socat)
    command -v rg &>/dev/null || missing+=(ripgrep)
    command -v setfacl &>/dev/null || missing+=(acl)

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "Missing apt packages: ${missing[*]}"
        if prompt_yn "Install them with apt?"; then
            dry_run_skip "sudo apt install -y ${missing[*]}" || {
                sudo apt update && sudo apt install -y "${missing[@]}"
            }
        fi
        echo ""
    fi

    # npm ls can write cache files, so skip the check entirely in dry-run
    if [[ "$DRY_RUN" == "true" ]]; then
        info "[dry-run] Would check for @anthropic-ai/sandbox-runtime and offer to install"
    elif ! npm ls -g @anthropic-ai/sandbox-runtime &>/dev/null 2>&1; then
        if prompt_yn "Install @anthropic-ai/sandbox-runtime globally via npm?"; then
            npm install -g @anthropic-ai/sandbox-runtime
        fi
    fi
    echo ""

    # ptrace_scope fix
    ptrace=$(cat /proc/sys/kernel/yama/ptrace_scope 2>/dev/null || echo "unknown")
    if [[ "$ptrace" == "0" ]]; then
        if prompt_yn "Set ptrace_scope to 1? (requires sudo)"; then
            dry_run_skip "set ptrace_scope to 1" || {
                echo 1 | sudo tee /proc/sys/kernel/yama/ptrace_scope >/dev/null
            }
            if prompt_yn "Make this permanent across reboots?"; then
                dry_run_skip "write /etc/sysctl.d/10-ptrace.conf" || {
                    echo "kernel.yama.ptrace_scope = 1" | sudo tee /etc/sysctl.d/10-ptrace.conf >/dev/null
                    ok "ptrace_scope set to 1 permanently"
                }
            else
                [[ "$DRY_RUN" == "false" ]] && ok "ptrace_scope set to 1 (until next reboot)"
            fi
        fi
        echo ""
    fi
fi

# 3. Claude Code steps (only if claude is installed)
CLAUDE_INSTALLED=false
if command -v claude &>/dev/null; then
    CLAUDE_INSTALLED=true
fi

if [[ "$CLAUDE_INSTALLED" == "false" ]]; then
    info "Claude Code is not installed - skipping Claude settings sync and claude-safe install"
    info "Install Claude Code (https://docs.claude.com/en/docs/claude-code) then re-run this script"
    echo ""
else
    echo "--- Claude Code settings ---"
    echo ""

    CLAUDE_SETTINGS="$HOME/.claude/settings.json"
    if [[ ! -f "$CLAUDE_SETTINGS" ]]; then
        if prompt_yn "No settings.json found. Create one from deny-paths.conf?"; then
            dry_run_skip "create $CLAUDE_SETTINGS from deny-paths.conf" || {
                mkdir -p "$HOME/.claude"
                "$BIN_DIR/sync-deny-paths"
            }
        fi
    else
        info "Existing settings found at $CLAUDE_SETTINGS"
        if prompt_yn "Sync deny-paths.conf into settings.json?"; then
            dry_run_skip "sync deny-paths.conf into $CLAUDE_SETTINGS" || {
                "$BIN_DIR/sync-deny-paths"
            }
        else
            echo "  You can sync later with: bin/sync-deny-paths"
            echo "  Preview first with:      bin/sync-deny-paths --dry-run"
        fi
    fi
    echo ""

    # 4. Symlink claude-safe to PATH
    echo "--- Install claude-safe to PATH ---"
    echo ""

    INSTALL_TARGET="$HOME/.local/bin/claude-safe"

    if [[ -f "$INSTALL_TARGET" || -L "$INSTALL_TARGET" ]]; then
        current_target=$(readlink -f "$INSTALL_TARGET" 2>/dev/null || echo "unknown")
        if [[ "$current_target" == "$BIN_DIR/claude-safe" ]]; then
            ok "claude-safe already linked to $INSTALL_TARGET"
        else
            if prompt_yn "claude-safe exists at $INSTALL_TARGET (points to $current_target). Replace it?"; then
                dry_run_skip "update symlink $INSTALL_TARGET -> $BIN_DIR/claude-safe" || {
                    ln -sf "$BIN_DIR/claude-safe" "$INSTALL_TARGET"
                    ok "Symlink updated"
                }
            fi
        fi
    else
        if prompt_yn "Symlink claude-safe to $INSTALL_TARGET?"; then
            dry_run_skip "symlink $INSTALL_TARGET -> $BIN_DIR/claude-safe" || {
                mkdir -p "$HOME/.local/bin"
                ln -sf "$BIN_DIR/claude-safe" "$INSTALL_TARGET"
                ok "Installed to $INSTALL_TARGET"
            }
        fi
    fi
fi

# Check if ~/.local/bin is in PATH
if ! echo "$PATH" | tr ':' '\n' | grep -q "$HOME/.local/bin"; then
    warn "$HOME/.local/bin is not in your PATH"
    echo "  Add this to your shell profile: export PATH=\"\$HOME/.local/bin:\$PATH\""
fi
echo ""

# 5. Make scripts executable and symlink grant helper
if [[ "$DRY_RUN" == "false" ]]; then
    # Only chmod if not already executable - avoids failing on files we don't
    # own (e.g. left over from runner-owned writes) when the bit is already set.
    _ensure_exec() {
        [[ -x "$1" ]] || chmod +x "$1"
    }
    _ensure_exec "$BIN_DIR/claude-safe"
    _ensure_exec "$BIN_DIR/sync-deny-paths"
    _ensure_exec "$BIN_DIR/sync-aiignore"
    _ensure_exec "$BIN_DIR/setup-claude-runner"
    _ensure_exec "$BIN_DIR/claude-safe-grant-access"
    _ensure_exec "$BIN_DIR/claude-safe-restrict-access"
    _ensure_exec "$SCRIPT_DIR/install.sh"

    mkdir -p "$HOME/.local/bin"

    GRANT_TARGET="$HOME/.local/bin/claude-safe-grant-access"
    if [[ ! -L "$GRANT_TARGET" || "$(readlink -f "$GRANT_TARGET")" != "$BIN_DIR/claude-safe-grant-access" ]]; then
        ln -sf "$BIN_DIR/claude-safe-grant-access" "$GRANT_TARGET"
        ok "Installed claude-safe-grant-access to $GRANT_TARGET"
    fi

    RESTRICT_TARGET="$HOME/.local/bin/claude-safe-restrict-access"
    if [[ ! -L "$RESTRICT_TARGET" || "$(readlink -f "$RESTRICT_TARGET")" != "$BIN_DIR/claude-safe-restrict-access" ]]; then
        ln -sf "$BIN_DIR/claude-safe-restrict-access" "$RESTRICT_TARGET"
        ok "Installed claude-safe-restrict-access to $RESTRICT_TARGET"
    fi
fi

# 6. Optional: claude-runner user isolation (needs claude installed)
if [[ ( "$SAFE_ASSISTANT_OS" == "linux" || "$SAFE_ASSISTANT_OS" == "macos" ) && "$CLAUDE_INSTALLED" == "true" ]]; then
    echo "--- Restricted user isolation (optional) ---"
    echo ""
    info "A separate '$RUNNER_USER' OS user prevents Claude from accessing"
    info "your personal files (~/.ssh, ~/.gnupg, etc.) at the OS level."
    echo ""
    if prompt_yn "Set up $RUNNER_USER restricted user? (requires sudo)"; then
        dry_run_skip "run bin/setup-claude-runner" || {
            "$BIN_DIR/setup-claude-runner"
        }
    else
        echo "  You can set this up later with: bin/setup-claude-runner"
    fi
    echo ""
fi

if [[ "$DRY_RUN" == "true" ]]; then
    echo "--- Dry run complete (no changes made) ---"
else
    echo "--- Done ---"
fi
echo ""
echo "Usage:"
echo ""
echo "  Launch Claude Code"
echo "    claude-safe                                    # run as isolated $RUNNER_USER user if available, else current user"
echo "    claude-safe --current-user                     # run as the current user"
echo "    claude-safe --strict                           # fail on any check"
echo "    claude-safe -- -p '...'                        # pass args through"
echo ""
echo "  Sync Claude Code deny rules from deny-paths.conf"
echo "    bin/sync-deny-paths                            # sync to ~/.claude/settings.json"
echo ""
echo "  Write .aiignore / .cursorignore / .codeiumignore for IDE assistants"
echo "    bin/sync-aiignore --dir /path/to/project       # write ignore files"
echo ""
echo "  Restricted user (Linux / macOS)"
echo "    bin/setup-claude-runner                        # create runner user"
echo "    claude-safe-grant-access DIR                   # grant runner access to DIR"
echo "    claude-safe-restrict-access DIR                # revoke runner access to DIR"
echo "    claude-safe-grant-access --revoke DIR          # equivalent to claude-safe-restrict-access"
echo ""
