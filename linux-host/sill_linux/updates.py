"""This host's version, and whether GitHub has a newer one.

It only checks. Installing is the user's choice: Update now in the tray, Update host in a viewer,
or `sill-linux-update` in a terminal. The hourly automatic update is off unless the user turns it
on (`update.sh --install`).
"""
import json
import logging
import os
import shutil
import subprocess
import threading
import time
import urllib.request

log = logging.getLogger("sill.updates")

REPO = "NateHag/Sill-Viewer"
FOLDER = "linux-host"
EVERY = 3600
UPDATER = os.path.expanduser("~/.local/bin/sill-linux-update")


def _read_build():
    """The commit this copy was packed from (the BUILD file in the download), or "dev"."""
    try:
        with open(os.path.join(os.path.dirname(__file__), "BUILD")) as f:
            b = f.read().strip()
        return b if len(b) == 40 and all(c in "0123456789abcdef" for c in b) else "dev"
    except OSError:
        return "dev"


BUILD = _read_build()


def short(sha):
    return sha[:7] if sha and sha != "dev" else (sha or "dev")


def _get(url):
    req = urllib.request.Request(url, headers={"User-Agent": "sill-linux", "Accept": "application/vnd.github+json"})
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.load(r)


def is_ahead(base, head):
    """True when `head` comes after `base` in GitHub's history: a newer version, not an older one
    and not one on another branch. GitHub's compare answers "ahead" exactly then."""
    try:
        return _get(f"https://api.github.com/repos/{REPO}/compare/{base}...{head}").get("status") == "ahead"
    except Exception:   # 404: GitHub does not know this build (never pushed); or no answer
        return False


def newest_commit():
    """The newest commit on GitHub's main that changed this host's folder."""
    data = _get(f"https://api.github.com/repos/{REPO}/commits?sha=main&path={FOLDER}&per_page=1")
    sha = data[0]["sha"] if isinstance(data, list) and data else None
    if not (isinstance(sha, str) and len(sha) == 40):
        raise ValueError("unexpected answer from GitHub")
    return sha


class Checker:
    """Asks GitHub once an hour. on_change() is called (from its thread) when the answer changes."""

    def __init__(self, on_change=None):
        self.newest = None
        self.newer = False      # GitHub's newest comes after this build (not merely differs)
        self.checked = 0.0
        self.on_change = on_change

    @property
    def available(self):
        return self.newer

    def start(self):
        threading.Thread(target=self._loop, name="update-check", daemon=True).start()

    def _loop(self):
        time.sleep(20)   # not while the host is starting
        while True:
            self.check()
            time.sleep(EVERY)

    def check(self):
        try:
            sha = newest_commit()
        except Exception as e:   # no network, rate limit, GitHub down: try again next hour
            log.info("update check: %s", e)
            return
        self.checked = time.time()
        if sha != self.newest:
            newer = BUILD != "dev" and sha != BUILD and is_ahead(BUILD, sha)
            self.newest, self.newer = sha, newer
            if newer:
                log.info("update available: this is %s, GitHub has %s", short(BUILD), short(sha))
            elif sha != BUILD:
                log.info("GitHub has %s; this build (%s) is not older, so no update", short(sha), short(BUILD))
            if self.on_change:
                self.on_change()


def can_update():
    return os.access(UPDATER, os.X_OK)


def run_update():
    """Starts the updater as its own systemd unit: it restarts this service, and a child of this
    service would be stopped with it. Returns a short note for the log and the user."""
    if not can_update():
        return "no updater installed: run update.sh --setup from the download"
    cmd = [UPDATER, "--force"]
    if shutil.which("systemd-run"):
        cmd = ["systemd-run", "--user", "--collect", "--quiet", f"--unit=sill-linux-update-now-{int(time.time())}"] + cmd
    try:
        subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    except OSError as e:
        return f"could not start the updater: {e}"
    log.info("update started: %s", " ".join(cmd))
    return "updating; Sill restarts in a few seconds"
