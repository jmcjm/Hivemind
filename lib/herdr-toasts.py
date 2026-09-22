#!/usr/bin/env python3
"""Turn herdr toasts on, unless the herdr config already says how to deliver them.

hive's alert for coordinator mail that nobody is watching is a herdr notification, and herdr's
default toast delivery is "off", so out of the box the alert never shows. install.sh runs this.

    herdr-toasts.py <config.toml> <backup-suffix>

Prints one status line:
    enabled <backup>  [ui.toast] delivery was unset and is now DELIVERY; <backup> is the copy of
                      the original, or "-" when there was no config file yet
    kept <value>      the config already chooses a delivery; nothing changed
    off-by-choice     the config sets delivery = "off" explicitly; respected, nothing changed
    error <reason>    nothing changed
"""
import os
import re
import shutil
import sys
import tempfile

# The OS notification service: the alert fires when the coordinator is not listening, which is
# usually when the human is looking at something other than herdr.
DELIVERY = "system"
# herdr rejects the WHOLE config for any other value ("unknown variant ..., using defaults").
VALID = ("off", "herdr", "terminal", "system")
HEADER = re.compile(r"^[ \t]*\[[ \t]*ui[ \t]*\.[ \t]*toast[ \t]*\][ \t]*(#[^\r\n]*)?\r?$", re.M)


def toast_delivery(cfg):
    ui = cfg.get("ui")
    toast = ui.get("toast") if isinstance(ui, dict) else None
    return toast.get("delivery") if isinstance(toast, dict) else None


def with_setting(text):
    """The config text with the setting placed under [ui.toast], added at the end when absent.
    New lines use the file's own line ending."""
    nl = "\r\n" if "\r\n" in text else "\n"
    setting = f'delivery = "{DELIVERY}"'
    header = HEADER.search(text)
    if header:
        end = header.end() - (1 if text[:header.end()].endswith("\r") else 0)
        return text[:end] + nl + setting + text[end:]
    if text and not text.endswith("\n"):
        text += nl
    return text + (nl if text else "") + "[ui.toast]" + nl + setting + nl


def write_atomically(target, text):
    """Replaces the file in one step, keeping its mode (a new file gets the umask default)."""
    directory = os.path.dirname(target) or "."
    os.makedirs(directory, exist_ok=True)
    if os.path.exists(target):
        mode = os.stat(target).st_mode & 0o7777
    else:
        umask = os.umask(0)
        os.umask(umask)
        mode = 0o666 & ~umask
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".herdr-toasts-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as f:
            f.write(text)
            f.flush()
            os.fsync(f.fileno())
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

    # A symlinked config is edited at its target, so it stays a link. A dangling one points at
    # something not there yet (a dotfiles checkout still to come) — creating it would get in the way.
    if os.path.islink(path) and not os.path.exists(path):
        return f"error {path} is a dangling symlink"
    target = os.path.realpath(path)

    try:
        with open(target, "rb") as f:
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
        if current not in VALID:
            return f"error [ui.toast] delivery = {current!r} is not one of {', '.join(VALID)} — herdr ignores the whole config"
        return f"kept {current}"

    # A read-only config is somebody saying "do not touch"; os.replace would ignore that.
    if raw is not None and not os.access(target, os.W_OK):
        return f"error {path} is read-only"

    new = with_setting(text)
    try:
        placed = toast_delivery(tomllib.loads(new)) == DELIVERY
    except tomllib.TOMLDecodeError:
        placed = False
    if not placed:                          # e.g. an inline or dotted toast table a header would clash with
        return "error the toast table is defined in a form this installer does not edit"

    backup = "-"
    try:
        if raw is not None:
            backup = target + suffix
            shutil.copy2(target, backup)
        write_atomically(target, new)
    except OSError as e:
        return f"error cannot write {path}: {e.strerror}"
    return f"enabled {backup}"


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: herdr-toasts.py <config.toml> <backup-suffix>")
    print(main(sys.argv[1], sys.argv[2]))
