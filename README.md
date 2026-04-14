# Safe-Assistant

Security-hardening tools for LLM coding assistants. Implements the recommendations from the [Fundraising AI Coding Assistant Safe Usage Guide](https://wikitech.wikimedia.org/wiki/Fundraising/AI).

Two kinds of protection:

- **Terminal assistants** (Claude Code) - `claude-safe` wrapper with hardening checks, env var stripping, and optional OS-level user isolation.
- **IDE-embedded assistants** (JetBrains AI, Cursor, Windsurf, Copilot Chat) - `.aiignore` / `.cursorignore` / `.codeiumignore` files generated from a shared deny list.

## Install

```bash
git clone https://github.com/jackgleeson/safe-assistant
cd safe-assistant
bash install.sh            # interactive setup
bash install.sh --dry-run  # preview without making changes
```

The installer verifies OS hardening settings, offers to install missing Linux deps via apt/npm, syncs `deny-paths.conf` into `~/.claude/settings.json`, symlinks `claude-safe` into `~/.local/bin/`, and (on Linux) offers to set up the `claude-runner` isolated user.

## Usage

```bash
claude-safe                          # Run Claude Code with hardening
claude-safe --current-user           # Always run as the current user
claude-safe --strict                 # Fail on any hardening check
claude-safe --skip-checks            # Skip hardening checks (still strips env vars)
claude-safe -- --model sonnet        # Pass args through to claude
```

What `claude-safe` does before launching Claude:

1. Verifies OS hardening (`ptrace_scope` on Linux, SIP on macOS) and sandbox deps (`bwrap`, `socat`, `ripgrep`, `@anthropic-ai/sandbox-runtime`).
2. Strips `SSH_AUTH_SOCK`, `GPG_AGENT_INFO`, and `DBUS_SESSION_BUS_ADDRESS` so the assistant cannot use your agents or D-Bus session.
3. Launches Claude, either as your user or as `claude-runner` if isolation is set up (see below).

## Isolation mode (Linux)

`claude-runner` is a separate Linux user account. When Claude runs as this user it **cannot** read your home directory: no `~/.ssh` or `~/.gnupg`, browser profiles, etc. It can only read and write the project directories you've explicitly granted, via POSIX ACLs.

This is a **stronger** boundary than the deny rules in `settings.json`, which rely on Claude's tool layer honestly matching patterns. OS-level user separation cannot be bypassed by clever bash commands.

One-time setup:

```bash
bin/setup-claude-runner                         # create user, configure sudoers, authenticate Claude
claude-safe-grant-access /path/to/project       # grant runner access to a project
claude-safe-grant-access --revoke /path/to/project  # revoke later
```

After setup, plain `claude-safe` automatically uses the runner when it's fully configured and falls back to running as your user (with a clear warning) otherwise.

## Deny list

`deny-paths.conf` is the single source of truth for what LLM assistants should not read. Commit it so the whole team shares the same rules.

Sync to Claude Code:

```bash
vim deny-paths.conf              # edit the shared list
bin/sync-deny-paths --dry-run    # preview changes
bin/sync-deny-paths              # apply to ~/.claude/settings.json
```

Using an IDE-embedded assistant (Cursor, Windsurf, Copilot, etc.)? Write ignore files into your project separately:

```bash
bin/sync-aiignore --dir /path/to/project    # writes .aiignore, .cursorignore, .codeiumignore
```

### deny-paths.conf format

```conf
# Glob patterns - become Read() permission deny rules and ignore file entries
**/*.env
**/*.key

# Concrete paths - also become sandbox.filesystem.denyRead entries
# ~ expands to $HOME, . is relative to project root
~/.ssh/*
./config-private
./LocalSettings.php

# Bash command deny rules (Claude Code only, not written to ignore files)
bash: node *
bash: npm *
```

## Security model

Multiple layers, none bulletproof alone.

**Protects against:**
- Accidental credential exposure via the deny list (`.ssh`, `.env`, `.key`, `.pem`, etc.)
- SSH/GPG/D-Bus agent leakage via env var stripping
- Weak OS hardening via ptrace_scope and SIP checks
- Policy drift across a team via the shared `deny-paths.conf`

**Recommendations:**
- Use `claude-runner` for OS-level isolation on Linux.
- Expand `deny-paths.conf` to cover credentials specific to your environment.
- Re-run `bin/sync-deny-paths` after every change. The script backs up `settings.json` automatically.

## Supported platforms

| Platform | Hardening checks | Env stripping | Deny sync | claude-runner |
|---|---|---|---|---|
| Linux (Debian/Ubuntu) | ✓ | ✓ | ✓ | ✓ |
| Linux (other distros) | ✓ | ✓ | ✓ | ✓ (install deps manually) |
| macOS | ✓ (SIP) | ✓ | ✓ | ✗ |
| Other | ✗ | — | — | — |

Requirements: Bash 4+, jq, Claude Code in PATH. Linux also needs bubblewrap, socat, ripgrep, acl, and `@anthropic-ai/sandbox-runtime` (installer can set these up on Debian/Ubuntu).

## Project structure

```
safe-assistant/
  bin/claude-safe                Launch wrapper
  bin/sync-deny-paths            Syncs deny-paths.conf to Claude Code settings.json
  bin/sync-aiignore              Writes .aiignore/.cursorignore/.codeiumignore for IDE assistants
  bin/setup-claude-runner        Creates the isolated claude-runner user (Linux)
  bin/claude-safe-grant-access   Grants runner ACL access to a project directory
  lib/check-platform.sh          Platform detection and output helpers
  lib/check-hardening.sh         OS hardening checks (ptrace, SIP)
  lib/check-sandbox.sh           Sandbox dependency checks
  lib/check-runner.sh            claude-runner verification helpers
  deny-paths.conf                Shared deny list (commit this)
  install.sh                     Interactive setup
```
