#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source_file="$script_dir/linux/codex-auth-linux.py"
install_dir="$HOME/.local/bin"

if [[ ! -f "$source_file" ]]; then
  printf 'Missing Linux codex-auth source: %s\n' "$source_file" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  printf 'Python 3 is required. Install python3 in WSL first.\n' >&2
  exit 1
fi

mkdir -p "$install_dir"
install -m 700 "$source_file" "$install_dir/codex-auth"

shell_rc="$HOME/.bashrc"
if [[ "${SHELL:-}" == */zsh ]]; then shell_rc="$HOME/.zshrc"; fi
path_line='export PATH="$HOME/.local/bin:$PATH"'
if [[ ":$PATH:" != *":$install_dir:"* ]] && ! grep -Fqx "$path_line" "$shell_rc" 2>/dev/null; then
  printf '\n%s\n' "$path_line" >> "$shell_rc"
  printf 'Added ~/.local/bin to %s. Open a new shell to use codex-auth by name.\n' "$shell_rc"
fi

printf 'Installed: %s/codex-auth\n' "$install_dir"
if ! command -v codex >/dev/null 2>&1; then
  printf 'Codex CLI was not found. Install the native Linux CLI in WSL first.\n'
fi
printf 'Run: codex-auth help\n'
