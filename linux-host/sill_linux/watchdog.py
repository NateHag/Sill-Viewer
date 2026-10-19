"""This user's switch for the display watchdog (display-watchdog/sill-display-watchdog).

The watchdog runs as root and restarts GDM when GNOME's desktop is stuck on a black screen.
It is off until the desktop's user turns it on here; it reads this file for that user.
"""
import json
import os
import time

PATH = os.path.expanduser("~/.config/sill-linux/display-watchdog.json")
INSTALLED = "/usr/local/sbin/sill-display-watchdog"
PAUSE_S = 4 * 3600


def installed():
    return os.path.exists(INSTALLED)


def load():
    try:
        with open(PATH) as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def save(**changes):
    data = load()
    data.update(changes)
    os.makedirs(os.path.dirname(PATH), exist_ok=True)
    tmp = PATH + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f)
    os.replace(tmp, PATH)
    return data


def enabled():
    return bool(load().get("enabled"))


def paused_until():
    """When the pause ends, or 0 when not paused."""
    t = float(load().get("pausedUntil") or 0)
    return t if t > time.time() else 0


def pause():
    save(pausedUntil=time.time() + PAUSE_S)


def resume():
    save(pausedUntil=0)


def describe():
    if not installed():
        return "The display watchdog is not installed (display-watchdog/install.sh)."
    if not enabled():
        return "Fixing a stuck black screen: off."
    p = paused_until()
    if p:
        return f"Fixing a stuck black screen: on, paused until {time.strftime('%H:%M', time.localtime(p))}."
    return "Fixing a stuck black screen: on."
