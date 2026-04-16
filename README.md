# Safe-Assistant

Security-hardening tooling for LLM coding assistants. Keeps one shared deny list for IDE assistants and Claude Code, and can run Claude in an isolated runner account for stronger OS-level protection. Implements the [Fundraising AI Coding Assistant Safe Usage Guide](https://wikitech.wikimedia.org/wiki/Fundraising/AI)

## Choose your workflow

- **Claude Code in the terminal** - install `claude-safe`. Go to [Quick start](#quick-start).
- **Claude Code inside a JetBrains IDE** - Go to [Quick start](#quick-start), then [JetBrains plugin](#jetbrains-plugin).
- **JetBrains AI / Cursor / Windsurf / VS Code / VS Codium**  no install needed. Generate ignore files for your project for all IDEs and commit to git. Done. Go to [IDE assistants](#ide-assistants).

## Quick start

1. Run `install.sh` to install `claude-safe` and create the runner account.
2. Approve project access with `claude-safe-grant-access /path/to/project`.
3. Start Claude with `claude-safe`.

```bash
git clone https://github.com/jackgleeson/safe-assistant
cd safe-assistant
bash install.sh            # interactive setup
bash install.sh --dry-run  # preview without making changes
```

`install.sh`:

- Verifies OS hardening (`ptrace_scope` on Linux, SIP on macOS).
- Offers to install missing Linux deps that [Claude Code's sandbox requires](https://code.claude.com/docs/en/sandboxing#prerequisites) via apt/npm.
- Syncs `deny-paths.conf` into `~/.claude/settings.json` and turns on Claude's bash sandbox (`sandbox.enabled: true`).
- Puts `claude-safe` on your `PATH`.
- Sets up the runner account (`claude-runner` on Linux, `_claude-runner` on macOS).

On macOS, Claude's OAuth sign-in for the runner account happens inline: a URL opens in your browser and you paste the returned code back into the runner's terminal.

## JetBrains plugin

The [Claude Code JetBrains plugin](https://plugins.jetbrains.com/plugin/27310-claude-code-beta-) runs Claude Code in an IDE panel instead of a terminal. To route it through `claude-safe`, open **Settings → Tools → Claude Code [Beta]** and set **Claude command** to `claude-safe`. Every session launched from the IDE then goes through the wrapper, with the same hardening checks, env stripping, and runner account as the CLI.

## Usage

```bash
claude-safe                                         # start Claude in the runner account
claude-safe-grant-access /path/to/project           # allow the runner account into a project
claude-safe-restrict-access /path/to/project        # remove that access again
```

If isolation is unavailable, `claude-safe` can fall back to your own user with a warning, but the recommended setup is to use the runner account for the strongest security. 

Flags:

```bash
claude-safe --strict                 # Fail on any hardening check
claude-safe --skip-checks            # Skip hardening checks (still strips env vars)
claude-safe -- --model opus        # Pass args through to claude
claude-safe --current-user           # Escape hatch: run as your own user instead of the runner account
```

`--current-user` is there for cases where you genuinely need access the runner doesn't have (debugging a tool, working on a file outside your approved projects). Use it sparingly: Claude then has the same reach you do. A useful exercise is to run `claude-safe` and `claude-safe --current-user` side by side in the same project and ask Claude what it can see. The difference is exactly what the runner account is protecting.

Before launch, `claude-safe`:

1. Verifies OS hardening: `ptrace_scope` plus sandbox deps (`bwrap`, `socat`, `ripgrep`, `@anthropic-ai/sandbox-runtime`) on Linux, SIP on macOS.
2. Verifies `sandbox.enabled: true` in the `settings.json` that the session will read (yours or the runner's), so Claude's bash sandbox is actually on.
3. Strips `SSH_AUTH_SOCK`, `GPG_AGENT_INFO`, and `DBUS_SESSION_BUS_ADDRESS` so Claude can't reuse your agents or D-Bus session.
4. Launches Claude, either as your user or as the runner account.

## Why the isolated runner account is safer

Safe-Assistant creates a separate, locked-down OS account called `claude-runner` (`_claude-runner` on macOS). The account has no password and can't be logged into. When Claude runs under it, the only folders it can open are the specific projects you've approved. Credentials, customer data, other projects, and every other file on the machine stay out of reach.

Without this, the standard Claude Code deny rules in `settings.json` only work if the assistant chooses to honour them. With an isolated account, the operating system does the blocking directly, so there's no prompt, command, or workaround that lets Claude reach files it hasn't been given access to. The account simply doesn't have permission.

## Re-syncing the deny list

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

## Verifying isolation

`claude-safe-access-status` scans under `$HOME` and prints every directory with a `claude-runner` (or `_claude-runner`) ACL entry, split into grants, explicit denies, and traverse-only ancestors:

```bash
claude-safe-access-status              # scan $HOME
claude-safe-access-status ~/Projects   # scan a subtree
```

For spot checks on a single path, you have passwordless sudo to the runner and can see exactly what it sees. Substitute `_claude-runner` on macOS.

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

## IDE assistants

No install step. Clone and sync:

```bash
git clone https://github.com/jackgleeson/safe-assistant  # skip if already cloned
cd safe-assistant
nano deny-paths.conf                          # add credentials specific to your environment
bin/sync-aiignore --dir /path/to/project      # writes all three ignore files into the project
```

Commit the generated ignore files in the target project. That's where the rules live with the code, get reviewed, and follow everyone who clones the project.

Re-run `bin/sync-aiignore` after any edit to `deny-paths.conf`.

For team-wide rules, fork this repo and keep your team's `deny-paths.conf` there as the shared baseline. Engineers pull from the fork and only update it when a new team-wide rule is added.

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

| Platform | Hardening checks | Env stripping | Deny sync | Runner account |
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

## Uninstall

```bash
bash uninstall.sh
```

Interactively reverses each step: removes the `~/.local/bin` symlinks, strips `deny-paths.conf` rules from `~/.claude/settings.json` (with a backup), deletes the `claude-runner` user (and group on macOS), revokes project ACLs granted via `claude-safe-grant-access`, and on Linux offers to remove `/etc/sysctl.d/10-ptrace.conf`. The repo itself is left in place.
