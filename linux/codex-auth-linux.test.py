#!/usr/bin/env python3
import base64
import json
import os
import subprocess
import tempfile
from pathlib import Path


TOOL = Path(__file__).with_name("codex-auth-linux.py")
INSTALLER = Path(__file__).resolve().parent.parent / "install-wsl.sh"


def auth(email, account, refreshed, marker):
    payload = base64.urlsafe_b64encode(json.dumps({"email": email}).encode()).decode().rstrip("=")
    return {
        "auth_mode": "chatgpt",
        "last_refresh": refreshed,
        "tokens": {"id_token": f"header.{payload}.signature", "account_id": account, "refresh_token": marker},
    }


with tempfile.TemporaryDirectory(prefix="codex-auth-linux-") as temporary:
    root = Path(temporary)
    shared = root / "windows"
    store = shared / "auth-profiles"
    local = root / "wsl"
    local.mkdir()
    fake = root / "codex"
    fake_server = root / "fake-app-server.py"
    log = root / "codex.log"
    fake_server.write_text(
        "import json, os, sys\n"
        "for line in sys.stdin:\n"
        "    message = json.loads(line)\n"
        "    if message.get('method') == 'initialize':\n"
        "        print(json.dumps({'id': 0, 'result': {}}), flush=True)\n"
        "    elif message.get('method') == 'thread/list':\n"
        "        threads = [\n"
        "            {'id': 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'cwd': os.environ['FAKE_CWD'], 'preview': 'Session A', 'updatedAt': 1000000000},\n"
        "            {'id': 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'cwd': '/other', 'preview': 'Session B', 'updatedAt': 1000000001},\n"
        "        ]\n"
        "        print(json.dumps({'id': message['id'], 'result': {'data': threads, 'nextCursor': None}}), flush=True)\n"
    )
    fake.write_text(
        "#!/bin/sh\n"
        "printf '%s|%s\\n' \"$CODEX_HOME\" \"$*\" >> \"$FAKE_CODEX_LOG\"\n"
        "if [ \"$1\" = app-server ] && [ \"$2\" != daemon ]; then exec python3 \"$FAKE_APP_SERVER\"; fi\n"
        "if [ \"$1\" = login ]; then printf '%s' \"$FAKE_LOGIN_AUTH\" > \"$CODEX_HOME/auth.json\"; fi\n"
    )
    fake.chmod(0o700)
    a = auth("a@example.com", "account-a", "2026-11-02T00:00:00Z", "old-a")
    a_new = auth("a@example.com", "account-a", "2026-11-04T00:00:00Z", "new-a")
    b = auth("b@example.com", "account-b", "2026-11-03T00:00:00Z", "b")
    for email, value in (("a@example.com", a), ("b@example.com", b)):
        path = store / "homes" / email / "auth.json"
        path.parent.mkdir(parents=True)
        path.write_text(json.dumps(value))
    (store / "profiles.json").write_text(json.dumps({"profiles": [
        {"email": "a@example.com", "home": "homes\\a@example.com", "added_at": "1", "account_id": "account-a"},
        {"email": "b@example.com", "home": "homes\\b@example.com", "added_at": "2", "account_id": "account-b"},
    ]}))
    (local / "auth.json").write_text(json.dumps(a_new))
    (local / "sessions").mkdir()
    (local / "sessions" / "old-session.jsonl").write_text("history")
    env = dict(os.environ, CODEX_AUTH_SHARED_HOME=str(shared), CODEX_AUTH_HOME=str(local),
               CODEX_AUTH_CODEX=str(fake), FAKE_CODEX_LOG=str(log),
               FAKE_APP_SERVER=str(fake_server), FAKE_CWD=str(root))

    def run(*args, extra_env=None):
        result = subprocess.run(["python3", str(TOOL), *args], cwd=root, env=dict(env, **(extra_env or {})),
                                text=True, capture_output=True)
        assert result.returncode == 0, f"{' '.join(args)}: {result.stderr}"
        return result.stdout

    assert "a@example.com" in run("status")
    run("next")
    assert json.loads((store / "homes/a@example.com/auth.json").read_text())["tokens"]["refresh_token"] == "new-a"
    assert json.loads((local / "auth.json").read_text())["tokens"]["account_id"] == "account-b"
    assert (local / "sessions/old-session.jsonl").read_text() == "history"
    assert 'cli_auth_credentials_store = "file"' in (local / "config.toml").read_text()
    assert "app-server daemon stop" in log.read_text()

    run("next")
    assert json.loads((local / "auth.json").read_text())["tokens"]["refresh_token"] == "new-a"
    run("run", "b@example.com", "--help")
    assert "--no-daemon --help" in log.read_text()

    c = auth("c@example.com", "account-c", "2026-11-05T00:00:00Z", "c")
    run("login", "c@example.com", extra_env={"FAKE_LOGIN_AUTH": json.dumps(c)})
    records = json.loads((store / "profiles.json").read_text())["profiles"]
    created = next(item for item in records if item["email"] == "c@example.com")
    assert (store / created["home"] / "auth.json").is_file()
    assert json.loads((local / "auth.json").read_text())["tokens"]["account_id"] == "account-c"
    assert "c@example.com" in run("list")
    assert "Session A" in run("sessions")
    assert "Session B" not in run("sessions")
    assert "Session B" in run("sessions", "--all")
    run("resume-all", "--all", "2")
    assert "--no-daemon resume bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" in log.read_text()

    fresh_shared = root / "fresh-windows"
    fresh_local = root / "fresh-wsl"
    fresh_local.mkdir()
    fresh_env = dict(env, CODEX_AUTH_SHARED_HOME=str(fresh_shared),
                     CODEX_AUTH_HOME=str(fresh_local), FAKE_LOGIN_AUTH=json.dumps(c))
    result = subprocess.run(["python3", str(TOOL), "login", "c@example.com"],
                            cwd=root, env=fresh_env, text=True, capture_output=True)
    assert result.returncode == 0, result.stderr
    assert (fresh_shared / "auth-profiles/profiles.json").is_file()
    assert (fresh_local / "auth.json").is_file()

    install_home = root / "install-home"
    install_home.mkdir()
    install_env = dict(os.environ, HOME=str(install_home), SHELL="/bin/bash")
    for _ in range(2):
        result = subprocess.run(["bash", str(INSTALLER)], cwd=root, env=install_env,
                                text=True, capture_output=True)
        assert result.returncode == 0, result.stderr
    assert (install_home / ".local/bin/codex-auth").is_file()
    assert (install_home / ".bashrc").read_text().count('export PATH="$HOME/.local/bin:$PATH"') == 1

print("codex-auth Linux shared-profile and session tests passed")
