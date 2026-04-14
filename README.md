# llm-safe

Security-hardening tools for LLM coding assistants. Implements the recommendations from the [Fundraising AI Coding Assistant Safe Usage Guide](https://wikitech.wikimedia.org/wiki/Fundraising/AI).

Covers two categories of assistant:

- **Terminal assistants** (Claude Code) - launch wrapper with pre-flight checks and env var stripping
- **IDE-embedded assistants** (JetBrains AI, Cursor, Windsurf, Copilot Chat) - generated ignore files from a shared deny list

## Install

```bash
git clone <repo-url> llm-safe
cd llm-safe
bash install.sh
```

Preview what the installer will do without making changes:

```bash
bash install.sh --dry-run
```

The installer will:
- Run pre-flight checks (ptrace_scope, SIP, sandbox dependencies)
- Offer to install missing Linux dependencies via apt/npm
- Offer to fix `ptrace_scope` if it's set to 0
- Sync `deny-paths.conf` into `~/.claude/settings.json`
- Symlink `claude-safe` to `~/.local/bin/`
- (Linux) Optionally set up `claude-runner` restricted user for OS-level isolation

## claude-safe

Launch wrapper for Claude Code. Runs pre-flight checks, strips sensitive environment variables (`SSH_AUTH_SOCK`, `GPG_AGENT_INFO`, `DBUS_SESSION_BUS_ADDRESS`), then execs `claude`.

```bash
claude-safe                          # Launch with hardening
claude-safe --strict                 # Fail on any check
claude-safe --skip-checks            # Just strip env vars and launch
claude-safe --as-runner              # Run as restricted claude-runner user (Linux)
claude-safe -- --model sonnet        # Pass args through to claude
```

## Managing deny paths

`deny-paths.conf` is the single source of truth for what LLM assistants should not read. Commit it to the repo so the whole team shares the same deny list. The sync script pushes it to:

- `~/.claude/settings.json` - Claude Code permissions and sandbox deny rules
- `.aiignore` / `.cursorignore` / `.codeiumignore` - IDE-embedded assistants

```bash
# Edit the shared deny list
vim deny-paths.conf

# Preview changes
bin/sync-deny-paths --dry-run

# Apply to Claude Code settings
bin/sync-deny-paths

# Also generate ignore files for IDE assistants in a project directory
bin/sync-deny-paths --aiignore-dir /path/to/project
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

### Workflow

1. Someone adds a path to `deny-paths.conf` and commits it
2. Others pull and run `bin/sync-deny-paths` to update their local settings
3. The installer also runs the sync during setup

## Restricted user isolation (Linux)

The `--as-runner` flag launches Claude as a separate OS user (`claude-runner`) that physically cannot access your personal files. This is stronger than deny rules alone, which still run under your user account.

```bash
# One-time setup (creates the user, syncs settings, configures sudoers)
bin/setup-claude-runner

# Authenticate Claude as the runner user
sudo -u claude-runner claude

# Launch with user isolation
claude-safe --as-runner
```

The runner user needs group read/write access to your project directories:

```bash
chmod -R g+rwX /path/to/project
```

## Project structure

```
llm-safe/
  bin/claude-safe           Claude Code launch wrapper
  bin/sync-deny-paths       Syncs deny-paths.conf to settings and ignore files
  bin/setup-claude-runner   Creates restricted claude-runner user (Linux)
  lib/check-platform.sh     Platform detection and output helpers
  lib/check-hardening.sh    OS hardening checks (ptrace, SIP)
  lib/check-sandbox.sh      Sandbox dependency checks
  lib/check-runner.sh       claude-runner user verification helpers
  deny-paths.conf           Shared deny list (commit this)
  templates/settings.json   Baseline Claude Code settings
  templates/aiignore        Starter .aiignore (manual alternative to sync)
  install.sh                Interactive setup
```

## Supported platforms

### Linux (Debian/Ubuntu)

Fully supported. The installer uses `apt` for dependency management, so package names assume Debian/Ubuntu. Other distros should work but you will need to install dependencies manually:

- **bubblewrap** (`bwrap`) - sandbox container
- **socat** - sandbox networking
- **ripgrep** (`rg`) - fast search
- **@anthropic-ai/sandbox-runtime** (npm) - seccomp filter for unix socket blocking
- **jq** - JSON processing for sync-deny-paths

The `claude-runner` user isolation feature uses standard Linux user management (`useradd`, `usermod`, `sudoers`).

### macOS

Partially supported. The scripts detect macOS, check SIP status, strip env vars, and sync deny paths. However, the installer does not manage dependencies on macOS. You will need to install ripgrep and jq manually (e.g. `brew install ripgrep jq`).

Not yet supported:
- Automated dependency installation
- `claude-runner` user isolation (`--as-runner`)

### Other platforms

Not supported. The scripts detect the platform and will warn on unrecognized systems.

## Requirements

- Bash 4+, jq
- Claude Code installed and available as `claude` in PATH
- Linux: bubblewrap, socat, ripgrep (installer can set these up)
- macOS: ripgrep (sandbox uses built-in sandbox-exec)
