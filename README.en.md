# codex-auth

**Switch Codex CLI accounts on Windows and WSL without signing in every time.**

[Tiếng Việt](README.md) · [Command reference](docs/commands.md)

`codex-auth` saves each ChatGPT login as a profile. `use` and `next` select the profile that the next `codex` process will load. Windows and WSL share saved credentials through the Windows profile store; each keeps its own active account, configuration, and session history.

## Features

- Save and switch between multiple Codex CLI accounts.
- Sign in once on Windows or WSL and reuse the saved profile on the other side.
- Keep `/resume` history together across accounts **within the same OS**.
- List and resume sessions across accounts with `sessions` and `resume-all`.
- Switch and launch Codex with `run` or `next-run`.
- Inspect the active account with `status` and confirm what Codex actually loaded with `verify`.
- Keep OS-specific SQLite databases, configuration, and sessions separate.

## Fresh-machine setup

### Windows

Install Git, Node.js, and Codex CLI following the [official CLI guide](https://learn.chatgpt.com/docs/cli):

```powershell
winget install OpenJS.NodeJS.LTS
winget install Git.Git
# Open a new PowerShell window after installing Node.js and Git.
npm.cmd install -g @openai/codex
codex --version
```

Install this tool:

```powershell
git clone https://github.com/hohphu8/codex-auth.git
cd codex-auth
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

The installer copies the Windows scripts to `%USERPROFILE%\.codex\bin` and adds that directory to your user PATH. Open a new PowerShell window, then run `codex-auth help` and `codex-auth doctor`. Use `-NoPath` with `install.ps1` to manage PATH yourself.

### WSL (optional)

If WSL is not installed yet, run `wsl --install` in an elevated Windows PowerShell and finish the reboot/Ubuntu setup. Then, **inside the WSL shell**, install a native Linux Codex CLI following the [official WSL guide](https://learn.chatgpt.com/docs/windows/wsl):

```bash
sudo apt update
sudo apt install -y python3 git
curl -fsSL https://chatgpt.com/codex/install.sh | sh
codex --version
```

Then install `codex-auth` inside WSL:

```bash
git clone https://github.com/hohphu8/codex-auth.git
cd codex-auth
bash ./install-wsl.sh
```

Open a new shell and run `codex-auth status`. The tool detects your Windows home through WSL interop. If interop is unavailable or several Windows user profiles exist, set `CODEX_AUTH_SHARED_HOME` to the Windows `.codex` directory:

```bash
export CODEX_AUTH_SHARED_HOME=/mnt/c/Users/<windows-user>/.codex
codex-auth status
```

Add the `export` to `~/.bashrc` or `~/.zshrc` if needed. You may install WSL first; the shared profile store is created by the first login.

## First accounts and daily use

On Windows, `login` opens a dedicated terminal for that account. Finish the Codex sign-in there and let the script save the profile:

```powershell
codex-auth login account1@example.com
codex-auth login account2@example.com
codex-auth list
codex-auth use 1
codex
```

The saved accounts are now available in WSL without another sign-in:

```bash
codex-auth list
codex-auth use 2
codex-auth verify
codex
```

You can also run `codex-auth login account3@example.com` in WSL; the new profile will appear on Windows. Exit an open Codex session before switching accounts, then start a new `codex` process.

If you previously signed in with plain `codex`, import that login:

```powershell
# Windows: supply the exact email of the current account.
codex-auth sync-active account1@example.com
```

```bash
# WSL: read the email from the current auth.json.
codex-auth sync
```

Useful commands:

```text
codex-auth list                 List saved profiles
codex-auth use 2                Select profile 2
codex-auth next                 Select the next profile
codex-auth run 2                Select profile 2 and launch Codex
codex-auth next-run             Select the next profile and launch Codex
codex-auth status               Show the selected account
codex-auth verify               Ask Codex which account it loaded
codex-auth sessions [--all]     List sessions in this directory or all directories
codex-auth resume-all [--all]   Pick and resume a session across accounts
```

See the [command reference](docs/commands.md) for all commands and OS differences.

## What is shared

The shared credential store lives in `%USERPROFILE%\.codex\auth-profiles` on Windows and is reached through `/mnt/c/Users/.../.codex/auth-profiles` in WSL. Windows and WSL keep separate `auth.json` files for the active account and separate session/configuration/SQLite state. `resume-all` searches across accounts **on the current OS**; it does not merge Windows sessions with WSL sessions.

If a token is refreshed while using plain `codex` in WSL, run `codex-auth sync` before using it on Windows. Switching accounts and exiting `run`, `next-run`, or `resume-all` also synchronize refreshed WSL credentials. Repositories under `/mnt/c` can be slower than repositories under `/home` when using WSL; see the [WSL guide](https://learn.chatgpt.com/docs/windows/wsl).

## Troubleshooting

| Problem | Action |
| --- | --- |
| `codex-auth` is not found | Open a new shell; check `%USERPROFILE%\.codex\bin` or `~/.local/bin` is on PATH. |
| The account did not change | Exit the old Codex process, run `codex-auth verify`, and check `CODEX_HOME`. |
| WSL starts the Windows CLI | Run `type -a codex`; the Linux binary should precede `/mnt/c/...`. |
| WSL cannot find the Windows profile store | Set `CODEX_AUTH_SHARED_HOME` as shown above. |
| A session is missing | Run `codex-auth sessions --all`; the default filters to the current directory. |
| Vietnamese titles are garbled on Windows | Update the repository and rerun `install.ps1` to install the Unicode-safe helper. |

## Security and limitations

`auth.json` and `auth-profiles/` contain login tokens. Never commit or publish them. The repository `.gitignore` excludes them. Use only accounts you are authorized to use and follow your organization and OpenAI limits.

`codex logout` may invalidate a saved token on both systems. This tool shares saved logins, but does not perform a synchronized logout. The active account and session history remain separate per OS.

Run the tests without real credentials:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\windows\codex-auth.test.ps1
node --check .\windows\codex-auth.probe.mjs
node --check .\windows\codex-auth.sessions.mjs
```

```bash
python3 linux/codex-auth-linux.test.py
python3 -m py_compile linux/codex-auth-linux.py
```
