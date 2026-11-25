# Command reference / Danh sách lệnh

Run `codex-auth help` for the commands installed on your OS. Profile indexes come from `codex-auth list` and start at 1. Email selectors are case-insensitive.

| Command | Windows | WSL | Purpose |
| --- | :---: | :---: | --- |
| `help` | ✓ | ✓ | Show usage. |
| `list` | ✓ | ✓ | Show saved profiles and active account. |
| `status` | ✓ | ✓ | Show the active auth file and matching profile. |
| `verify` | ✓ | ✓ | Ask a fresh native Codex process which account it loaded. |
| `login <email>` | ✓ | ✓ | Sign in and save the result for both systems. Windows opens a dedicated terminal. |
| `use <email\|index>` | ✓ | ✓ | Stop the local daemon and select a saved profile. Exit open Codex sessions first. |
| `next` | ✓ | ✓ | Select the next saved profile. |
| `run <email\|index> [args]` | ✓ | ✓ | Select a profile and launch Codex with the local shared session home. |
| `next-run [args]` | ✓ | ✓ | Select the next profile and launch Codex. |
| `sessions [--all]` | ✓ | ✓ | List local sessions across accounts; default filters to current directory. |
| `resume-all [--all]` | ✓ | ✓ | Pick a session across accounts and resume it. WSL also accepts an optional number or UUID. |
| `sync` | ✓ | ✓ | Windows: refresh metadata for a named profile (`sync <email>`). WSL: publish the current WSL login. |
| `sync-active <email>` | ✓ | — | Import the current Windows `auth.json` under the given email. |
| `run-isolated <email\|index>` | ✓ | — | Run Codex with that profile's private home and session history. |
| `doctor` | ✓ | — | Check profile files, email mismatches, PATH, and `CODEX_HOME`. |
| `remove <email\|index>` | ✓ | — | Delete a saved profile from the shared store. |
| `clean [--dry-run] [--backups] [--days N]` | ✓ | — | Delete generated leftovers and optionally old backups. Preview with `--dry-run`. |
| `env` | ✓ | — | Show commands for removing a conflicting `CODEX_HOME`. |
| `install-user [--no-path]` | ✓ | — | Copy the Windows command and helpers into the user's Codex bin directory. |

## Typical flows / Ví dụ

```text
codex-auth login a@example.com
codex-auth login b@example.com
codex-auth list
codex-auth use 2
codex-auth verify
codex
```

```text
codex-auth sessions --all
codex-auth resume-all --all
```

`/resume` is a Codex CLI command inside the TUI. `resume-all` is a `codex-auth` command you run in your shell. Both use local sessions for the current OS; neither copies session history between Windows and WSL.

## Environment variables

| Variable | Where | Meaning |
| --- | --- | --- |
| `CODEX_AUTH_HOME` | Windows, WSL | Override the local Codex home used by `codex-auth`. Mostly useful for tests. |
| `CODEX_AUTH_DEFAULT_HOME` | Windows | Alternate override for the default Codex home. |
| `CODEX_AUTH_SHARED_HOME` | WSL | Path to the Windows `.codex` home, for example `/mnt/c/Users/alice/.codex`. |
| `CODEX_AUTH_CODEX` | WSL | Override the native Linux Codex executable; useful for tests. |
| `CODEX_HOME` | Codex CLI | Codex's own home. If set to a different directory, plain `codex` may not use the account chosen by `codex-auth`. |

Do not set `CODEX_AUTH_SHARED_HOME` to the `auth-profiles` directory itself; set it to its parent `.codex` directory.
