#!/usr/bin/env python3
"""Codex account profiles for WSL, backed by the Windows codex-auth store."""

import base64
import datetime as dt
import hashlib
import json
import os
import re
import select
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path


def discover_windows_home():
    configured = os.environ.get("CODEX_AUTH_SHARED_HOME")
    if configured:
        return Path(configured).expanduser()
    for executable in (shutil.which("cmd.exe"), "/mnt/c/Windows/System32/cmd.exe"):
        if not executable:
            continue
        try:
            profile = subprocess.run([executable, "/c", "echo", "%USERPROFILE%"],
                                     capture_output=True, timeout=5)
            if profile.returncode:
                continue
            windows_path = profile.stdout.decode("utf-8-sig", errors="replace").strip()
            converted = subprocess.run(["wslpath", "-u", windows_path],
                                       capture_output=True, text=True, timeout=5)
            if converted.returncode == 0 and converted.stdout.strip():
                return Path(converted.stdout.strip()) / ".codex"
        except (OSError, subprocess.TimeoutExpired):
            continue
    candidates = list(Path("/mnt/c/Users").glob("*/.codex/auth-profiles/profiles.json"))
    if len(candidates) == 1:
        return candidates[0].parent.parent
    return None


WINDOWS_HOME = discover_windows_home()
STORE = WINDOWS_HOME / "auth-profiles" if WINDOWS_HOME else None
META = STORE / "profiles.json" if STORE else None
LOCAL_HOME = Path(os.environ.get("CODEX_AUTH_HOME", os.environ.get("CODEX_HOME", str(Path.home() / ".codex")))).expanduser()
LOCAL_AUTH = LOCAL_HOME / "auth.json"


def die(message):
    raise RuntimeError(message)


def read_json(path):
    with path.open("r", encoding="utf-8-sig") as stream:
        return json.load(stream)


def atomic_write(path, data, mode=0o600):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".codex-auth-", dir=str(path.parent))
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def copy_auth(source, destination):
    atomic_write(destination, source.read_bytes())


def profiles():
    if STORE is None:
        die("Cannot locate Windows Codex home. Set CODEX_AUTH_SHARED_HOME to /mnt/c/Users/<windows-user>/.codex.")
    if not META.is_file():
        return []
    records = read_json(META).get("profiles", [])
    return sorted(records, key=lambda item: (item.get("added_at") or "", item.get("email") or ""))


def profile_home(profile):
    relative = (profile.get("home") or "").replace("\\", "/")
    if not relative:
        die(f"Profile has no home: {profile.get('email')}")
    result = (STORE / relative).resolve()
    if STORE.resolve() not in result.parents:
        die(f"Profile home is outside shared store: {relative}")
    return result


def source_auth(profile):
    return profile_home(profile) / "auth.json"


def jwt_email(token):
    try:
        payload = token.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        return json.loads(base64.urlsafe_b64decode(payload)).get("email")
    except (IndexError, ValueError, json.JSONDecodeError):
        return None


def auth_info(path):
    if not path.is_file():
        return None
    auth = read_json(path)
    tokens = auth.get("tokens") or {}
    return {
        "account_id": tokens.get("account_id"),
        "email": jwt_email(tokens.get("id_token") or ""),
        "refresh": auth.get("last_refresh") or "",
        "mode": auth.get("auth_mode"),
    }


def identity_matches(left, right):
    if not left or not right:
        return False
    if left["account_id"] and right["account_id"]:
        return left["account_id"] == right["account_id"]
    return bool(left["email"] and right["email"] and left["email"].lower() == right["email"].lower())


def matching_profile(info, records):
    if not info:
        return None
    for profile in records:
        summary = auth_info(source_auth(profile))
        if identity_matches(info, summary):
            return profile
        if info["account_id"] and profile.get("account_id") == info["account_id"]:
            return profile
        if info["email"] and profile.get("email", "").lower() == info["email"].lower():
            return profile
    return None


def newer(source, target):
    source_info = auth_info(source)
    target_info = auth_info(target)
    if not source_info:
        return False
    if not target_info:
        return True
    if not identity_matches(source_info, target_info):
        die("Refusing to replace a saved profile with a different account.")
    if source_info["refresh"] != target_info["refresh"]:
        return source_info["refresh"] > target_info["refresh"]
    if source.read_bytes() == target.read_bytes():
        return False
    return source.stat().st_mtime > target.stat().st_mtime + 1


def publish_new_profile(email, auth_path):
    email = email.strip().lower()
    info = auth_info(auth_path)
    if not info or info["mode"] != "chatgpt" or not info["email"]:
        die("Login did not create a ChatGPT auth.json with an email.")
    if info["email"].lower() != email:
        die(f"Login email {info['email']} does not match requested profile {email}.")
    records = profiles()
    existing = next((item for item in records if item.get("email", "").lower() == email), None)
    if existing:
        target = source_auth(existing)
        if newer(auth_path, target):
            copy_auth(auth_path, target)
        return existing

    digest = hashlib.sha256(email.encode()).hexdigest()[:12]
    home_relative = f"homes/p-{digest}"
    target = STORE / home_relative / "auth.json"
    if target.exists() and not identity_matches(info, auth_info(target)):
        die(f"Profile path collision: {target}")
    if newer(auth_path, target):
        copy_auth(auth_path, target)
    now = dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")
    profile = {
        "email": email,
        "home": home_relative,
        "added_at": now,
        "updated_at": now,
        "auth_present": True,
        "auth_mode": info["mode"],
        "last_refresh": info["refresh"],
        "account_id": info["account_id"],
        "token_email": info["email"],
        "sha256": hashlib.sha256(target.read_bytes()).hexdigest(),
    }
    records.append(profile)
    atomic_write(META, (json.dumps({"profiles": records}, indent=2, ensure_ascii=False) + "\n").encode())
    return profile


def sync_current():
    info = auth_info(LOCAL_AUTH)
    if not info:
        return None
    records = profiles()
    profile = matching_profile(info, records)
    if not profile:
        if info["email"] and info["mode"] == "chatgpt":
            profile = publish_new_profile(info["email"], LOCAL_AUTH)
            print(f"Imported WSL login into shared profiles: {profile['email']}")
        else:
            print("WSL auth is not a saved ChatGPT profile; skipped sync.", file=sys.stderr)
            return None
    target = source_auth(profile)
    if newer(LOCAL_AUTH, target):
        copy_auth(LOCAL_AUTH, target)
        print(f"Saved refreshed WSL auth for: {profile['email']}")
    return profile


def native_codex():
    candidates = [Path(os.environ["CODEX_AUTH_CODEX"]).expanduser()] if os.environ.get("CODEX_AUTH_CODEX") else []
    candidates.append(Path.home() / ".local/bin/codex")
    found = shutil.which("codex")
    if found:
        candidates.append(Path(found))
    for candidate in candidates:
        if candidate.is_file() and os.access(candidate, os.X_OK) and not str(candidate).startswith("/mnt/"):
            return str(candidate)
    die("No native Linux Codex CLI found. Install it in WSL, then retry. The /mnt/c/Program Files/nodejs/codex command is the Windows package and cannot run with WSL Node 12.")


def codex_env(home=LOCAL_HOME):
    env = dict(os.environ)
    env["CODEX_HOME"] = str(home)
    return env


def ensure_file_credentials(home):
    home.mkdir(parents=True, exist_ok=True)
    config = home / "config.toml"
    text = config.read_text(encoding="utf-8") if config.exists() else ""
    section = re.search(r"(?m)^\s*\[", text)
    head = text[:section.start()] if section else text
    tail = text[section.start():] if section else ""
    setting = 'cli_auth_credentials_store = "file"\n'
    pattern = re.compile(r"(?m)^\s*cli_auth_credentials_store\s*=\s*[^\r\n]*(?:\r?\n|$)")
    head = pattern.sub(setting, head, count=1) if pattern.search(head) else setting + head
    updated = head + tail
    if updated != text:
        atomic_write(config, updated.encode("utf-8"))


def select_profile(selector, records):
    if selector.isdigit():
        index = int(selector) - 1
        if 0 <= index < len(records):
            return records[index]
        die(f"Profile index out of range: {selector}")
    for profile in records:
        if profile.get("email", "").lower() == selector.lower():
            return profile
    die(f"Unknown profile: {selector}")


def stop_daemon(codex):
    result = subprocess.run([codex, "app-server", "daemon", "stop"], env=codex_env(), capture_output=True, text=True)
    if result.returncode:
        die(f"Could not stop the WSL Codex daemon: {(result.stderr or result.stdout).strip()}")


def use_profile(selector):
    codex = native_codex()
    sync_current()
    profile = select_profile(selector, profiles())
    source = source_auth(profile)
    if not source.is_file():
        die(f"No shared auth for {profile['email']}. Login once on Windows or WSL first.")
    ensure_file_credentials(LOCAL_HOME)
    stop_daemon(codex)
    copy_auth(source, LOCAL_AUTH)
    print(f"WSL Codex account: {profile['email']}")
    return profile


def next_profile():
    records = [profile for profile in profiles() if source_auth(profile).is_file()]
    if not records:
        die("No shared profiles with auth found.")
    current = matching_profile(auth_info(LOCAL_AUTH), records)
    if not current:
        return records[0]
    index = next(i for i, profile in enumerate(records) if profile["email"] == current["email"])
    return records[(index + 1) % len(records)]


def run_codex(codex, arguments):
    args = arguments[1:] if arguments[:1] == ["--"] else arguments
    command = [codex] + ([] if "--no-daemon" in args else ["--no-daemon"]) + args
    try:
        return subprocess.call(command, env=codex_env())
    finally:
        sync_current()


def saved_sessions(all_directories=False):
    codex = native_codex()
    with subprocess.Popen([codex, "app-server"], env=codex_env(), stdin=subprocess.PIPE,
                          stdout=subprocess.PIPE, stderr=subprocess.DEVNULL) as process:
        pending = []
        buffer = bytearray()
        deadline = time.monotonic() + 45

        def send(message):
            process.stdin.write((json.dumps(message) + "\n").encode())
            process.stdin.flush()

        def receive(request_id):
            while time.monotonic() < deadline:
                for index, message in enumerate(pending):
                    if message.get("id") == request_id:
                        pending.pop(index)
                        if message.get("error"):
                            die(f"Codex app-server request failed: {message['error'].get('message')}")
                        return message.get("result") or {}
                ready, _, _ = select.select([process.stdout.fileno()], [], [], 1)
                if not ready:
                    continue
                chunk = os.read(process.stdout.fileno(), 8192)
                if not chunk:
                    die("Codex app-server exited while listing sessions.")
                buffer.extend(chunk)
                while b"\n" in buffer:
                    line, _, remainder = buffer.partition(b"\n")
                    buffer[:] = remainder
                    try:
                        pending.append(json.loads(line))
                    except ValueError:
                        continue
            die("Timed out listing Codex sessions.")

        try:
            send({"method": "initialize", "id": 0, "params": {"clientInfo": {
                "name": "codex_auth_linux_sessions", "title": "codex-auth Linux sessions", "version": "1.0.0"}}})
            receive(0)
            send({"method": "initialized", "params": {}})
            threads = []
            cursors = set()
            cursor = None
            for request_id in range(1, 102):
                send({"method": "thread/list", "id": request_id, "params": {
                    "currentAccountOnly": False, "modelProviders": [],
                    "sourceKinds": ["cli", "vscode"], "sortKey": "updated_at",
                    "limit": 100, "cursor": cursor}})
                result = receive(request_id)
                threads.extend(result.get("data") or [])
                cursor = result.get("nextCursor")
                if not cursor:
                    break
                if cursor in cursors:
                    die("Codex session pagination repeated a cursor.")
                cursors.add(cursor)
            else:
                die("Codex returned too many pages of sessions.")
        finally:
            process.stdin.close()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()

    if all_directories:
        return threads
    current = Path.cwd().resolve()
    return [thread for thread in threads if thread.get("cwd") and Path(thread["cwd"]).resolve() == current]


def show_sessions(all_directories=False):
    threads = saved_sessions(all_directories)
    if not threads:
        print("No saved sessions found here. Try: codex-auth sessions --all")
        return threads
    print(f"{'#':>3}  {'Updated':16}  Title")
    for index, thread in enumerate(threads, start=1):
        updated = thread.get("updatedAt")
        when = dt.datetime.fromtimestamp(int(updated)).strftime("%Y-%m-%d %H:%M") if updated else ""
        title = " ".join(str(thread.get("name") or thread.get("preview") or "(untitled)").split())
        if len(title) > 65:
            title = title[:62] + "..."
        print(f"{index:>3}  {when:16}  {title}")
    return threads


def resume_all(arguments):
    all_directories = "--all" in arguments
    choices = [argument for argument in arguments if argument != "--all"]
    if len(choices) > 1:
        die("Usage: codex-auth resume-all [--all] [number|session ID]")
    threads = show_sessions(all_directories)
    if not threads:
        return 0
    try:
        choice = choices[0] if choices else input("Session number or ID (blank to cancel): ").strip()
    except EOFError:
        return 0
    if not choice:
        return 0
    if choice.isdigit():
        index = int(choice) - 1
        if not 0 <= index < len(threads):
            die(f"Session number out of range: {choice}")
        session_id = threads[index]["id"]
    elif re.fullmatch(r"[0-9a-fA-F]{8}-[0-9a-fA-F-]{27,}", choice):
        session_id = choice
    else:
        die("Enter a session number or UUID.")
    return run_codex(native_codex(), ["resume", session_id])


def show_list():
    records = profiles()
    current = matching_profile(auth_info(LOCAL_AUTH), records)
    for index, profile in enumerate(records, start=1):
        marker = "*" if current and current["email"] == profile["email"] else " "
        available = "yes" if source_auth(profile).is_file() else "no"
        print(f"{index:>3} {marker} {available:>3}  {profile['email']}")


def verify_account():
    codex = native_codex()
    expected = matching_profile(auth_info(LOCAL_AUTH), profiles())
    with subprocess.Popen([codex, "app-server"], env=codex_env(), stdin=subprocess.PIPE,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1) as process:
        try:
            def send(message):
                process.stdin.write(json.dumps(message) + "\n")
                process.stdin.flush()

            send({"method": "initialize", "id": 0, "params": {
                "clientInfo": {"name": "codex_auth_linux", "title": "codex-auth Linux verification", "version": "1.0.0"}}})
            deadline = dt.datetime.now().timestamp() + 20
            while dt.datetime.now().timestamp() < deadline:
                ready, _, _ = select.select([process.stdout], [], [], 1)
                if not ready:
                    continue
                line = process.stdout.readline()
                if not line:
                    die("Codex app-server exited before account/read.")
                message = json.loads(line)
                if message.get("id") == 0:
                    if message.get("error"):
                        die(f"Codex initialize failed: {message['error'].get('message')}")
                    send({"method": "initialized", "params": {}})
                    send({"method": "account/read", "id": 1, "params": {"refreshToken": False}})
                elif message.get("id") == 1:
                    if message.get("error"):
                        die(f"Codex account/read failed: {message['error'].get('message')}")
                    actual = (message.get("result") or {}).get("account") or {}
                    email = actual.get("email")
                    print(f"Codex Linux loaded: {email or actual.get('type') or '(none)'}")
                    if expected and email and email.lower() == expected["email"].lower():
                        print("OK: native Linux Codex loaded the selected profile.")
                        return
                    die("Codex Linux loaded a different account than the selected profile.")
            die("Timed out waiting for Codex account/read.")
        finally:
            process.stdin.close()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


def login(email):
    codex = native_codex()
    digest = hashlib.sha256(email.strip().lower().encode()).hexdigest()[:12]
    private_home = LOCAL_HOME / "p" / digest
    if not (private_home / "config.toml").exists() and (LOCAL_HOME / "config.toml").exists():
        private_home.mkdir(parents=True, exist_ok=True)
        shutil.copy2(LOCAL_HOME / "config.toml", private_home / "config.toml")
    ensure_file_credentials(private_home)
    result = subprocess.call([codex, "login"], env=codex_env(private_home))
    if result:
        return result
    profile = publish_new_profile(email, private_home / "auth.json")
    print(f"Saved login for Windows and WSL: {profile['email']}")
    use_profile(profile["email"])
    return 0


def main(argv):
    if not argv or argv[0] in ("-h", "--help", "help"):
        print("""codex-auth for WSL (shared Windows profile store)

  codex-auth list                  List accounts saved on Windows or WSL
  codex-auth status                Show active WSL account
  codex-auth verify                Ask native Linux Codex which account it loaded
  codex-auth sync                  Save a refreshed WSL login to shared profiles
  codex-auth login <email>         Login once in WSL and save for both systems
  codex-auth use <email|index>     Switch WSL Codex to a saved account
  codex-auth next                  Switch to the next saved account
  codex-auth run <email|index>     Switch and launch native Linux Codex
  codex-auth next-run              Switch and launch native Linux Codex
  codex-auth sessions [--all]      List WSL sessions across saved accounts
  codex-auth resume-all [--all]    Pick and resume a WSL session across accounts

Windows and WSL keep separate session/config state. Login tokens are shared through
the Windows codex-auth profile store. Avoid `codex logout` when retaining profiles.
""")
        return 0
    command = argv[0]
    if command == "list":
        show_list()
    elif command == "status":
        current = matching_profile(auth_info(LOCAL_AUTH), profiles())
        print(f"WSL CODEX_HOME: {LOCAL_HOME}")
        print(f"Shared store: {STORE}")
        print(f"Active account: {current['email'] if current else '(not saved or signed out)'}")
    elif command == "verify":
        verify_account()
    elif command == "sync":
        profile = sync_current()
        if profile:
            print(f"Shared auth ready: {profile['email']}")
    elif command == "login":
        if len(argv) < 2:
            die("Usage: codex-auth login <email>")
        return login(argv[1])
    elif command == "use":
        if len(argv) < 2:
            die("Usage: codex-auth use <email|index>")
        use_profile(argv[1])
    elif command == "next":
        use_profile(next_profile()["email"])
    elif command == "run":
        if len(argv) < 2:
            die("Usage: codex-auth run <email|index> [Codex arguments]")
        use_profile(argv[1])
        return run_codex(native_codex(), argv[2:])
    elif command == "next-run":
        use_profile(next_profile()["email"])
        return run_codex(native_codex(), argv[1:])
    elif command == "sessions":
        if len(argv) > 2 or (len(argv) == 2 and argv[1] != "--all"):
            die("Usage: codex-auth sessions [--all]")
        show_sessions("--all" in argv[1:])
    elif command == "resume-all":
        return resume_all(argv[1:])
    else:
        die(f"Unknown command: {command}. Run codex-auth help.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except (OSError, ValueError, RuntimeError) as error:
        print(f"codex-auth: {error}", file=sys.stderr)
        sys.exit(1)
