# Safe-Assistant

Security-hardening tools for LLM coding assistants. Implements the recommendations from the [Fundraising AI Coding Assistant Safe Usage Guide](https://wikitech.wikimedia.org/wiki/Fundraising/AI).

## How it works

`deny-paths.conf` is the shared source of truth: one list of files LLM assistants should not read, synced into two targets, with an optional stronger isolation layer.

- **Shared deny list** - you edit `deny-paths.conf`; everything else is generated.
- **IDE assistants** - `bin/sync-aiignore` writes `.aiignore`, `.cursorignore`, and `.codeiumignore` into your projects.
- **CLI assistants (Claude Code)** - `bin/sync-deny-paths` writes deny rules into `~/.claude/settings.json`, and `claude-safe` wraps `claude` with hardening checks and env var stripping.
- **Optional OS-user isolation** - `claude-runner` runs Claude as a separate OS user that can't read your home directory. Linux and macOS.

Supported IDE assistants: JetBrains AI, Cursor, Windsurf, VS Code, VS Codium.

## Quick start (IDE assistants)

No install step. Clone and sync:

```bash
git clone https://github.com/jackgleeson/safe-assistant
cd safe-assistant
nano deny-paths.conf                          # add credentials specific to your environment
bin/sync-aiignore --dir /path/to/project      # writes all three ignore files into the project
```

Commit the generated ignore files in the target project. That's where the rules live with the code, get reviewed, and follow everyone who clones the project.

Re-run `bin/sync-aiignore` after any edit to `deny-paths.conf`.

For team-wide rules, fork this repo and keep your team's `deny-paths.conf` there as the shared baseline. Engineers pull from the fork and only update it when a new team-wide rule is added.

## CLI assistants (Claude Code)

The `claude-safe` wrapper runs hardening checks and strips sensitive env vars before launching `claude`. A one-time install puts it on your `PATH` and syncs deny rules into `~/.claude/settings.json`.

### Install

```bash
git clone https://github.com/jackgleeson/safe-assistant  # skip if already cloned
cd safe-assistant
bash install.sh            # interactive setup
bash install.sh --dry-run  # preview without making changes
```

The installer verifies OS hardening (ptrace_scope on Linux, SIP on macOS), offers to install missing Linux deps via apt/npm, syncs `deny-paths.conf` into `~/.claude/settings.json`, symlinks `claude-safe` into `~/.local/bin/`, and offers to set up the `claude-runner` isolated user (Linux or macOS).

### Uninstall

```bash
bash uninstall.sh
```

Interactively reverses each step: removes the `~/.local/bin` symlinks, strips `deny-paths.conf` rules from `~/.claude/settings.json` (with a backup), deletes the `claude-runner` user (and group on macOS), revokes project ACLs granted via `claude-safe-grant-access`, and on Linux offers to remove `/etc/sysctl.d/10-ptrace.conf`. The repo itself is left in place.

### Usage

```bash
claude-safe                          # Run Claude Code with hardening
claude-safe --current-user           # Always run as the current user
claude-safe --strict                 # Fail on any hardening check
claude-safe --skip-checks            # Skip hardening checks (still strips env vars)
claude-safe -- --model sonnet        # Pass args through to claude
```

Before launch, `claude-safe`:

1. Verifies OS hardening: `ptrace_scope` plus sandbox deps (`bwrap`, `socat`, `ripgrep`, `@anthropic-ai/sandbox-runtime`) on Linux, SIP on macOS.
2. Strips `SSH_AUTH_SOCK`, `GPG_AGENT_INFO`, and `DBUS_SESSION_BUS_ADDRESS` so Claude can't use your agents or D-Bus session.
3. Launches Claude, either as your user or as the runner user (`claude-runner` on Linux, `_claude-runner` on macOS) if isolation is set up.

### Re-syncing the deny list

After editing `deny-paths.conf`:

```bash
bin/sync-deny-paths --dry-run    # preview changes
bin/sync-deny-paths              # apply to ~/.claude/settings.json
```

Concrete paths also become `sandbox.filesystem.denyRead` entries. You can add bash command deny rules that only apply to Claude Code:

```conf
# Bash command deny rules (Claude Code only, not written to ignore files)
bash: node *
bash: npm *
```

## Optional OS-user isolation

`claude-runner` is a dedicated OS user account (`claude-runner` on Linux, `_claude-runner` on macOS) with no password and no login shell access. When Claude runs as this user, the kernel refuses every read or write to anything outside the project directories you've explicitly granted: your SSH private keys, GPG keyring, `.env` files in other projects, shell history, and any other file owned by your user are all unreachable. Access is granted per-project via file ACLs (POSIX on Linux, native ACLs on macOS), and revoked with `claude-safe-restrict-access`.

This is a substantially stronger guarantee than the deny rules in `settings.json`, which depend on Claude's tool layer correctly classifying every tool call and matching every glob. Those rules are policy. OS-level user separation is enforced by the kernel on every syscall, so no amount of creative `bash` invocation, symlink trickery, or prompt injection can bypass it: the runner simply doesn't have permission.

One-time setup:

```bash
bin/setup-claude-runner                             # create user, configure sudoers, authenticate Claude
claude-safe-grant-access /path/to/project           # grant runner access to a project
claude-safe-restrict-access /path/to/project        # revoke runner access later
```

After setup, plain `claude-safe` automatically uses the runner when it's fully configured and falls back to running as your user (with a clear warning) otherwise.

On macOS, the OAuth auth step runs inline: `setup-claude-runner` launches `sudo -u _claude-runner -i claude`, Claude prints an auth URL that opens in your browser, and you paste the code back into the runner's terminal.

### Verifying isolation

Because you have passwordless sudo to the runner, you can check exactly what the runner can and can't see without launching Claude. Substitute `_claude-runner` on macOS.

```bash
# Should succeed: runner can read a granted project.
sudo -u claude-runner ls ~/Projects/granted-project

# Should fail with "Permission denied": your home directory is off-limits.
sudo -u claude-runner ls ~/
sudo -u claude-runner cat ~/.ssh/id_rsa

# Should fail: a path you've run 'claude-safe-restrict-access' on is
# explicitly denied, regardless of 'other' permission bits.
sudo -u claude-runner ls ~/Projects/restricted-project

# Show the ACL on a path (Linux). Look for 'user:claude-runner:---' (deny)
# or 'user:claude-runner:rwx' (grant).
getfacl -p ~/Projects/granted-project

# Show the ACL on a path (macOS).
ls -lde ~/Projects/granted-project
```

## Reference

### deny-paths.conf format

```conf
# Glob patterns
**/*.env
**/*.key

# Concrete paths
# ~ expands to $HOME, . is relative to project root
~/.ssh/*
./config-private
./LocalSettings.php
```

### Supported platforms

Applies to `claude-safe` only. The IDE assistant flow (`bin/sync-aiignore`) works anywhere Bash runs.

| Platform | Hardening checks | Env stripping | Deny sync | claude-runner |
|---|---|---|---|---|
| Linux (Debian/Ubuntu) | ✓ | ✓ | ✓ | ✓ |
| Linux (other distros) | ✓ | ✓ | ✓ | ✓ (install deps manually) |
| macOS (12+) | ✓ (SIP) | ✓ | ✓ | ✓ |
| Other | ✗ | - | - | - |

### Requirements

All platforms: Bash 4+, Claude Code in `PATH`, and:

- **jq** - JSON processor used by `sync-deny-paths` and the installer to read/merge/write `~/.claude/settings.json` safely.

Linux also needs:

- **bubblewrap (`bwrap`)** - Unprivileged sandboxing tool. Creates isolated namespaces (mount, PID, user, network) so Claude's sandbox runtime can execute bash in a restricted view of the filesystem. Core building block of `@anthropic-ai/sandbox-runtime`.
- **socat** - Bidirectional data relay. The sandbox runtime uses it to proxy stdio and sockets across the namespace boundary between the sandbox and the host.
- **ripgrep (`rg`)** - Fast recursive search. Claude Code invokes it directly for the Grep tool; without it code search inside a sandboxed session is slow or broken.
- **acl (`setfacl`/`getfacl`)** - POSIX Access Control Lists. `claude-safe-grant-access` uses `setfacl` to give the `claude-runner` user read/write on specific project directories without broadening standard Unix permissions.
- **`@anthropic-ai/sandbox-runtime`** (npm) - Anthropic's sandbox orchestrator. Wraps `bwrap` and `socat` into the runtime Claude Code invokes when it needs to run untrusted bash, and enforces the `sandbox.filesystem` deny rules from `settings.json`.

macOS: SIP is verified via the built-in `csrutil`; no extra packages required.

The installer can install all Linux packages on Debian/Ubuntu via `apt` and `npm`.
