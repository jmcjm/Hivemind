#!/usr/bin/env python3
"""What herdr itself announces for every turn a background agent ends. Read-only.

herdr notifies about a background agent that finishes or needs input with a toast ([ui.toast]
delivery) and a sound ([ui.sound]). Neither can be limited to one pane, so in a swarm both fire
for every turn every drone ends. install.sh runs this to warn about them.

    herdr-pings.py <config.toml>

Prints "<toast delivery> <sound for Claude Code agents: on|off>" with herdr's defaults filled in
(toasts off, sounds on), or "unknown unknown" when the config cannot be read.
"""
import sys


def table(cfg, *keys):
    """The nested table at keys, or {} when any step is missing or not a table."""
    for key in keys:
        cfg = cfg.get(key) if isinstance(cfg, dict) else None
    return cfg if isinstance(cfg, dict) else {}


def pings(path):
    import tomllib                          # Python 3.11+
    try:
        with open(path, "rb") as f:
            cfg = tomllib.loads(f.read().decode("utf-8-sig"))   # an editor may have left a BOM
    except FileNotFoundError:
        cfg = {}                            # no config: herdr's defaults
    delivery = table(cfg, "ui", "toast").get("delivery") or "off"
    claude = table(cfg, "ui", "sound", "agents").get("claude", "default")
    enabled = table(cfg, "ui", "sound").get("enabled", True) is not False
    sound = claude == "on" or (claude != "off" and enabled)
    return f"{delivery} {'on' if sound else 'off'}"


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: herdr-pings.py <config.toml>")
    try:
        print(pings(sys.argv[1]))
    except Exception:                       # unreadable, not TOML, Python older than 3.11
        print("unknown unknown")
