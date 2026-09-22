#!/usr/bin/env python3
"""Turn herdr toasts on, unless the herdr config already says how to deliver them.

hive's alert for coordinator mail that nobody is watching is a herdr notification, and herdr's
default toast delivery is "off", so out of the box the alert never shows. install.sh runs this.

    herdr-toasts.py <config.toml> <backup-suffix>

Prints one status line:
    enabled         [ui.toast] delivery was unset; it is now DELIVERY (original kept as <config><suffix>)
    kept <value>    the config already chooses a delivery; nothing changed
    off-by-choice   the config sets delivery = "off" explicitly; respected, nothing changed
    error <reason>  nothing changed
"""
import os
import re
import shutil
import sys
import tempfile

# The OS notification service: the alert fires when the coordinator is not listening, which is
# usually when the human is looking at something other than herdr.
DELIVERY = "system"
SETTING = f'delivery = "{DELIVERY}"'


def toast_delivery(cfg):
    ui = cfg.get("ui")
    toast = ui.get("toast") if isinstance(ui, dict) else None
    return toast.get("delivery") if isinstance(toast, dict) else None


def with_setting(text):
    """The config text with the setting placed under [ui.toast], added at the end when absent."""
    header = re.search(r"^[ \t]*\[[ \t]*ui[ \t]*\.[ \t]*toast[ \t]*\][ \t]*(#.*)?$", text, re.M)
    if header:
        return text[:header.end()] + "\n" + SETTING + text[header.end():]
    if text and not text.endswith("\n"):
        text += "\n"
    return text + ("\n" if text else "") + "[ui.toast]\n" + SETTING + "\n"


def write_atomically(path, text):
    """Replaces the file in one step, keeping its mode. A symlinked config stays a symlink."""
    target = os.path.realpath(path)
    directory = os.path.dirname(target) or "."
    os.makedirs(directory, exist_ok=True)
    mode = os.stat(target).st_mode & 0o7777 if os.path.exists(target) else 0o644
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".herdr-toasts-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        os.chmod(tmp, mode)
        os.replace(tmp, target)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def main(path, suffix):
    try:
        import tomllib                      # Python 3.11+
    except ImportError:
        return "error python3 >= 3.11 is needed to read TOML"

    try:
        with open(path, "rb") as f:
            raw = f.read()
    except FileNotFoundError:
        raw = None
    except OSError as e:
        return f"error cannot read {path}: {e.strerror}"

    try:
        text = raw.decode("utf-8-sig") if raw is not None else ""
        current = toast_delivery(tomllib.loads(text))
    except (UnicodeDecodeError, tomllib.TOMLDecodeError) as e:
        return f"error {path} is not valid TOML: {e}"

    if current == "off":
        return "off-by-choice"
    if current is not None:
        return f"kept {current}"

    new = with_setting(text)
    try:
        placed = toast_delivery(tomllib.loads(new)) == DELIVERY
    except tomllib.TOMLDecodeError:
        placed = False
    if not placed:                          # e.g. an inline toast table that a header would clash with
        return "error the toast table is defined in a form this installer does not edit"

    try:
        if raw is not None:
            target = os.path.realpath(path)
            shutil.copy2(target, target + suffix)
        write_atomically(path, new)
    except OSError as e:
        return f"error cannot write {path}: {e.strerror}"
    return "enabled"


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: herdr-toasts.py <config.toml> <backup-suffix>")
    print(main(sys.argv[1], sys.argv[2]))
