#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$SCRIPT_DIR/bin"
LIB_DIR="$SCRIPT_DIR/lib"

source "$LIB_DIR/check-platform.sh"

INVOKING_USER="$(logname 2>/dev/null || echo "$USER")"

# --- Helpers ---

prompt_yn() {
    local question="$1" default="${2:-n}"
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

if [[ "$(id -u)" -eq 0 ]]; then
    fail "Do not run this script as root. It will use sudo as needed."
fi

detect_platform

RUNNER_HOME="$RUNNER_HOME_BASE/$RUNNER_USER"
RUNNER_CLAUDE_DIR="$RUNNER_HOME/.claude"
SUDOERS_FILE="/etc/sudoers.d/$RUNNER_USER"

echo ""
echo "safe-assistant uninstaller"
echo "=========================="
echo ""

# --- 1. Remove PATH symlinks ---

echo "--- Remove PATH symlinks ---"
echo ""

for name in claude-safe claude-safe-grant-access; do
    target="$HOME/.local/bin/$name"
    if [[ -L "$target" ]]; then
        resolved="$(readlink -f "$target" 2>/dev/null || echo "")"
        if [[ "$resolved" == "$BIN_DIR/$name" ]]; then
            if prompt_yn "Remove symlink $target?"; then
                rm "$target"
                ok "Removed $target"
            fi
        else
            warn "$target exists but points elsewhere ($resolved) - skipping"
        fi
    else
        info "$HOME/.local/bin/$name not found - skipping"
    fi
done

echo ""

# --- 2. Remove deny-path rules from ~/.claude/settings.json ---

echo "--- Remove deny-path rules from Claude Code settings ---"
echo ""

SETTINGS_FILE="$HOME/.claude/settings.json"
CONF_FILE="$SCRIPT_DIR/deny-paths.conf"

if [[ ! -f "$SETTINGS_FILE" ]]; then
    info "No settings.json found at $SETTINGS_FILE - skipping"
elif ! command -v jq &>/dev/null; then
    warn "jq not found - cannot auto-remove deny rules from $SETTINGS_FILE"
    warn "Remove manually: permissions.deny and sandbox.filesystem.denyRead entries from deny-paths.conf"
elif [[ ! -f "$CONF_FILE" ]]; then
    warn "deny-paths.conf not found at $CONF_FILE - cannot determine which rules to remove"
else
    # Build arrays of rules that were written by this tool
    read_deny_rules=()
    bash_deny_rules=()
    sandbox_deny_paths=()

    while IFS= read -r line; do
        line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [[ -z "$line" || "$line" == \#* ]] && continue

        if [[ "$line" == bash:* ]]; then
            cmd="${line#bash:}"
            cmd="$(echo "$cmd" | sed 's/^[[:space:]]*//')"
            bash_deny_rules+=("Bash($cmd)")
            continue
        fi

        expanded="${line/#\~/$HOME}"
        read_deny_rules+=("Read($line)")
        if [[ "$line" != *'*'* && "$line" != *'?'* ]]; then
            sandbox_deny_paths+=("$expanded")
        fi
    done < "$CONF_FILE"

    all_perms_rules=("${read_deny_rules[@]+"${read_deny_rules[@]}"}" "${bash_deny_rules[@]+"${bash_deny_rules[@]}"}")
    perms_filter=$(printf '%s\n' "${all_perms_rules[@]+"${all_perms_rules[@]}"}" | jq -R . | jq -s .)
    sandbox_filter=$(printf '%s\n' "${sandbox_deny_paths[@]+"${sandbox_deny_paths[@]}"}" | jq -R . | jq -s .)

    existing=$(cat "$SETTINGS_FILE")
    updated=$(echo "$existing" | jq \
        --argjson perms_remove "$perms_filter" \
        --argjson sandbox_remove "$sandbox_filter" \
        '
        if .permissions.deny then
            .permissions.deny = [.permissions.deny[] | select(. as $r | $perms_remove | index($r) | not)]
        else . end
        |
        if .sandbox.filesystem.denyRead then
            .sandbox.filesystem.denyRead = [.sandbox.filesystem.denyRead[] | select(. as $r | $sandbox_remove | index($r) | not)]
        else . end
        ')

    if [[ "$existing" == "$updated" ]]; then
        info "No safe-assistant deny rules found in $SETTINGS_FILE - skipping"
    else
        echo "  Rules to remove from $SETTINGS_FILE:"
        old_perms=$(echo "$existing" | jq -r '.permissions.deny // [] | .[]' | sort)
        new_perms=$(echo "$updated"  | jq -r '.permissions.deny // [] | .[]' | sort)
        comm -23 <(echo "$old_perms") <(echo "$new_perms") | sed 's/^/    - permissions.deny: /'

        old_sandbox=$(echo "$existing" | jq -r '.sandbox.filesystem.denyRead // [] | .[]' | sort)
        new_sandbox=$(echo "$updated"  | jq -r '.sandbox.filesystem.denyRead // [] | .[]' | sort)
        comm -23 <(echo "$old_sandbox") <(echo "$new_sandbox") | sed 's/^/    - sandbox.filesystem.denyRead: /'

        echo ""
        if prompt_yn "Remove these rules from $SETTINGS_FILE?"; then
            backup_file="${SETTINGS_FILE}.backup.$(date +%Y%m%dT%H%M%S)"
            cp "$SETTINGS_FILE" "$backup_file"
            ok "Backed up existing settings to $backup_file"
            echo "$updated" | jq . > "$SETTINGS_FILE"
            ok "Updated $SETTINGS_FILE"
        fi
    fi
fi

echo ""

# --- 3. Remove runner user isolation ---

_runner_exists() {
    case "$SAFE_ASSISTANT_OS" in
        linux) id "$RUNNER_USER" &>/dev/null ;;
        macos) dscl . -read "/Users/$RUNNER_USER" &>/dev/null 2>&1 ;;
    esac
}

if _runner_exists; then
    echo "--- Remove runner user isolation ---"
    echo ""
    info "The following will be removed:"
    [[ -f "$SUDOERS_FILE" ]] && echo "  - Sudoers rule: $SUDOERS_FILE"
    [[ -L /usr/local/bin/claude ]] && echo "  - Symlink: /usr/local/bin/claude"
    echo "  - User account: $RUNNER_USER"
    echo "  - Home directory: $RUNNER_HOME"
    [[ "$SAFE_ASSISTANT_OS" == "macos" ]] && echo "  - Group: $RUNNER_USER"
    echo "  - ACL traverse entries on the claude binary path"
    echo ""

    if prompt_yn "Remove $RUNNER_USER user and all associated setup?"; then

        # 3a. Sudoers rule
        if [[ -f "$SUDOERS_FILE" ]]; then
            sudo rm -f "$SUDOERS_FILE"
            ok "Removed $SUDOERS_FILE"
        fi

        # 3b. /usr/local/bin/claude symlink (only if it was ours)
        if [[ -L /usr/local/bin/claude ]]; then
            link_target="$(readlink /usr/local/bin/claude)"
            if [[ "$link_target" == "$HOME"* || "$link_target" == *"/.local/bin/claude"* ]]; then
                sudo rm -f /usr/local/bin/claude
                ok "Removed /usr/local/bin/claude symlink"
            else
                warn "/usr/local/bin/claude points to $link_target - not ours, skipping"
            fi
        fi

        # 3c. Remove ACL traverse entries from claude binary path dirs
        CLAUDE_PATH="$(command -v claude 2>/dev/null || true)"
        if [[ -n "$CLAUDE_PATH" && "$CLAUDE_PATH" != /usr/local/bin/* && "$CLAUDE_PATH" != /usr/bin/* && "$CLAUDE_PATH" != /opt/homebrew/* ]]; then
            RESOLVED_PATH="$(readlink -f "$CLAUDE_PATH")"
            RESOLVED_DIR="$(dirname "$RESOLVED_PATH")"
            acl_dirs=()
            dir="$RESOLVED_DIR"
            while [[ "$dir" != "/" ]]; do
                acl_dirs=("$dir" "${acl_dirs[@]+"${acl_dirs[@]}"}")
                dir="$(dirname "$dir")"
            done
            for dir in "${acl_dirs[@]+"${acl_dirs[@]}"}"; do
                if [[ "$SAFE_ASSISTANT_OS" == "macos" ]]; then
                    sudo chmod -a "user:$RUNNER_USER allow execute" "$dir" 2>/dev/null || true
                else
                    sudo setfacl -x "u:$RUNNER_USER" "$dir" 2>/dev/null || true
                fi
            done
            ok "Removed ACL traverse entries from claude binary path"
        fi

        # 3d. Delete user, group, home directory
        if [[ "$SAFE_ASSISTANT_OS" == "macos" ]]; then
            sudo dscl . -delete "/Users/$RUNNER_USER" 2>/dev/null || true
            ok "Deleted user $RUNNER_USER"
            if dscl . -read "/Groups/$RUNNER_USER" &>/dev/null 2>&1; then
                sudo dscl . -delete "/Groups/$RUNNER_USER" 2>/dev/null || true
                ok "Deleted group $RUNNER_USER"
            fi
            if [[ -d "$RUNNER_HOME" ]]; then
                sudo rm -rf "$RUNNER_HOME"
                ok "Removed home directory $RUNNER_HOME"
            fi
        else
            sudo userdel -r "$RUNNER_USER" 2>/dev/null || true
            ok "Deleted user $RUNNER_USER (and home directory)"
        fi
    fi
    echo ""
fi

# --- 4. Remove project ACL grants ---

echo "--- Remove project ACL grants ---"
echo ""

# Remove a single ACE for RUNNER_USER from one directory by index (non-recursive).
# Used for traverse-only (execute) ACEs on ancestor directories.
_remove_runner_aces_macos() {
    local dir="$1"
    local indices
    indices="$(ls -lde "$dir" 2>/dev/null \
        | awk -v u="$RUNNER_USER" '
            /^[[:space:]]+[0-9]+:/ {
                n=$1; sub(/:$/,"",n);
                if ($0 ~ ("user:" u " ")) print n
            }' \
        | sort -rn)"
    for i in $indices; do
        sudo chmod -a# "$i" "$dir" 2>/dev/null || true
    done
}

# Scan HOME shallowly for dirs with RUNNER_USER ACL entries.
# Prunes large dirs that will never contain project roots.
_PRUNE_MACOS=( -name 'Library' -o -name 'node_modules' -o -name '.git'
               -o -name '.nvm' -o -name '.npm' -o -name '.cache'
               -o -name '.Trash' -o -name 'Applications' )
_PRUNE_LINUX=( -name 'node_modules' -o -name '.git' -o -name '.nvm'
               -o -name '.npm' -o -name '.cache' )

if [[ "$SAFE_ASSISTANT_OS" == "macos" ]]; then
    info "Scanning $HOME for directories with $RUNNER_USER ACL entries (depth ≤ 5, common dirs pruned)..."
    runner_dirs=()
    while IFS= read -r d; do
        runner_dirs+=("$d")
    done < <(find "$HOME" -maxdepth 5 \
        \( "${_PRUNE_MACOS[@]}" \) -prune \
        -o -type d -exec bash -c \
            'ls -led "$1" 2>/dev/null | grep -q "'"$RUNNER_USER"'" && echo "$1"' _ {} \; \
        2>/dev/null || true)

    if [[ ${#runner_dirs[@]} -eq 0 ]]; then
        info "No directories with $RUNNER_USER ACL entries found"
    else
        # Split into project dirs (have inheritance ACE → full recursive revoke)
        # and traverse dirs (execute-only ACE → remove single ACE from that dir).
        project_dirs=()
        traverse_dirs=()
        for d in "${runner_dirs[@]+"${runner_dirs[@]}"}"; do
            if ls -led "$d" 2>/dev/null | grep -q "file_inherit,directory_inherit"; then
                project_dirs+=("$d")
            else
                traverse_dirs+=("$d")
            fi
        done

        if [[ ${#project_dirs[@]} -gt 0 ]]; then
            echo "  Project dirs (will be recursively revoked):"
            printf '    %s\n' "${project_dirs[@]+"${project_dirs[@]}"}"
        fi
        if [[ ${#traverse_dirs[@]} -gt 0 ]]; then
            echo "  Ancestor dirs with traverse-only ACE:"
            printf '    %s\n' "${traverse_dirs[@]+"${traverse_dirs[@]}"}"
        fi
        echo ""

        if prompt_yn "Remove $RUNNER_USER ACL entries from these directories?"; then
            for d in "${project_dirs[@]+"${project_dirs[@]}"}"; do
                "$BIN_DIR/claude-safe-grant-access" --revoke "$d"
            done
            for d in "${traverse_dirs[@]+"${traverse_dirs[@]}"}"; do
                _remove_runner_aces_macos "$d"
            done
            ok "Removed $RUNNER_USER ACL entries"
            warn "Note: 'chmod o-rwx' locks on sibling dirs and the home dir itself were not reversed."
            warn "If any directories lost 'other' read/execute permissions, restore with:"
            warn "  chmod o+rx <dir>"
            warn "To restore your home directory: chmod o+rx $HOME"
        fi
    fi

elif [[ "$SAFE_ASSISTANT_OS" == "linux" ]]; then
    if ! command -v getfacl &>/dev/null; then
        warn "getfacl not found - skipping ACL scan (install acl package to clean up manually)"
    else
        info "Scanning $HOME for directories with $RUNNER_USER ACL entries (depth ≤ 5, common dirs pruned)..."
        runner_dirs=()
        while IFS= read -r d; do
            runner_dirs+=("$d")
        done < <(find "$HOME" -maxdepth 5 \
            \( "${_PRUNE_LINUX[@]}" \) -prune \
            -o -type d -exec bash -c \
                'getfacl -p "$1" 2>/dev/null | grep -q "'"$RUNNER_USER"'" && echo "$1"' _ {} \; \
            2>/dev/null || true)

        if [[ ${#runner_dirs[@]} -eq 0 ]]; then
            info "No directories with $RUNNER_USER ACL entries found"
        else
            echo "  Directories with $RUNNER_USER ACL entries:"
            printf '    %s\n' "${runner_dirs[@]+"${runner_dirs[@]}"}"
            echo ""
            if prompt_yn "Remove $RUNNER_USER ACL entries from these directories?"; then
                for d in "${runner_dirs[@]+"${runner_dirs[@]}"}"; do
                    "$BIN_DIR/claude-safe-grant-access" --revoke "$d" 2>/dev/null || \
                        sudo setfacl -R -x "u:$RUNNER_USER" "$d" 2>/dev/null || true
                done
                ok "Removed $RUNNER_USER ACL entries"
                warn "Note: 'chmod o-rwx' locks on sibling dirs and the home dir itself were not reversed."
                warn "If any directories lost 'other' read/execute permissions, restore with:"
                warn "  chmod o+rx <dir>"
                warn "To restore your home directory: chmod o+rx $HOME"
            fi
        fi
    fi
fi

echo ""

# --- 5. Linux: remove ptrace_scope config ---

if [[ "$SAFE_ASSISTANT_OS" == "linux" ]]; then
    PTRACE_CONF="/etc/sysctl.d/10-ptrace.conf"
    if [[ -f "$PTRACE_CONF" ]] && grep -q "ptrace_scope" "$PTRACE_CONF"; then
        echo "--- Linux: ptrace_scope ---"
        echo ""
        if prompt_yn "Remove $PTRACE_CONF (restores ptrace_scope to system default on next boot)?"; then
            sudo rm -f "$PTRACE_CONF"
            ok "Removed $PTRACE_CONF"
            info "ptrace_scope will revert to the system default on next reboot"
        fi
        echo ""
    fi
fi

# --- Done ---

echo "--- Done ---"
echo ""
info "The safe-assistant project directory itself was not removed."
info "Delete it manually if no longer needed: rm -rf $SCRIPT_DIR"
echo ""
