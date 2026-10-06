# -*- coding: utf-8 -*-
"""config_io.py - load, edit, check and save a prep_vulcan YAML config without disturbing its layout.

The config file is the session. ruamel.yaml (round trip) parses it and says on which line and column each
value starts, but its dump respaces the hand-aligned flow lists of these configs (35-49 lines change), so this
module never dumps. It keeps the file's text and replaces only the text of the edited value on its own line,
keeping that line's comment where it was. A save with no edit therefore writes the original bytes.
Every edit is verified by re-parsing the whole text with ruamel.yaml and with PyYAML (prep_vulcan.py's own
parser): the edited key must read back as the new value and every other value must be unchanged.
Saving is Save as only: the open file and any existing file are never overwritten, and prep's own
load_config must accept the new file (checked on a temporary file next to the target) before it is renamed
into place.

@author ben kay
:license: MIT
"""
from __future__ import annotations

import io
import json
import math
import os
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import yaml
from ruamel.yaml import YAML

from . import prep_api


class ConfigError(Exception):
    """An edit, a check or a save of the config was refused; the message says why."""


@dataclass
class ConfigDoc:
    """One open config: its file, its current (possibly edited) text and the text last read or saved.

    Attributes:
        path: The file the text was read from or last saved as.
        text: The current text, with every edit applied.
        saved_text: The text as it is on disk.
        data: ruamel.yaml's round-trip parse of text (CommentedMap).
    """

    path: Path
    text: str
    saved_text: str
    data: Any

    @property
    def dirty(self) -> bool:
        """True while the text differs from the file on disk."""
        return self.text != self.saved_text

    def get(self, dotted: str, default: Any = None) -> Any:
        """Return the plain value at a dotted key, e.g. 'data.error_floor_Z', or default if it is absent."""
        try:
            parent, key = _locate(self.data, dotted)
        except ConfigError:
            return default
        return plain(parent[key])


def local_path(path: str | os.PathLike) -> Path:
    """Return path as an absolute local path, refusing network and WSL paths.

    Args:
        path: A path from a dialog, the command line or the recent-files list.

    Raises:
        ConfigError: for a UNC path (two leading slashes or backslashes: a server share, wsl$ or
            wsl.localhost): the GUI uses local files only, and opening a WSL path would start WSL.
    """
    s = os.fspath(path)
    if s.replace(chr(92), "/").startswith("//"):
        raise ConfigError("refused: %s is a network or WSL path; the GUI opens local files only" % s)
    return Path(os.path.abspath(s))


def _parse(text: str) -> Any:
    return YAML(typ="rt").load(text)


def load(path: str | os.PathLike) -> ConfigDoc:
    """Read a config file.

    Raises:
        ConfigError: if the path is refused, the file cannot be read or it is not a YAML mapping.
    """
    p = local_path(path)
    try:
        with open(p, encoding="utf-8", newline="") as fh:
            text = fh.read()
        data = _parse(text)
    except Exception as e:                  # OSError, UnicodeDecodeError, ruamel's YAMLError family
        raise ConfigError("cannot read %s: %s" % (p, e)) from None
    if not hasattr(data, "lc"):
        raise ConfigError("%s is not a YAML mapping" % p)
    return ConfigDoc(path=p, text=text, saved_text=text, data=data)


def plain(v: Any) -> Any:
    """Convert ruamel's round-trip types to plain dict, list, float, int, bool, str and None."""
    if isinstance(v, dict):
        return {str(k): plain(x) for k, x in v.items()}
    if isinstance(v, (list, tuple)):
        return [plain(x) for x in v]
    if isinstance(v, bool) or v is None:
        return v
    if isinstance(v, int):
        return int(v)
    if isinstance(v, float):
        return float(v)
    return str(v)


def _locate(data: Any, dotted: str) -> tuple[Any, str]:
    keys = dotted.split(".")
    cur = data
    for k in keys[:-1]:
        if not isinstance(cur, dict) or k not in cur:
            raise ConfigError("the config has no key %s" % dotted)
        cur = cur[k]
    if not isinstance(cur, dict) or keys[-1] not in cur:
        raise ConfigError("the config has no key %s" % dotted)
    return cur, keys[-1]


def format_value(v: Any) -> str:
    """Return YAML text for v that ruamel.yaml (YAML 1.2) and PyYAML (YAML 1.1, prep's parser) read alike.

    Floats are written as repr with a decimal point and a signed exponent (PyYAML reads '1e-05' as a string),
    lists in flow style, None as null.

    Raises:
        ConfigError: for a non-finite float or an unsupported type.
    """
    if v is None:
        return "null"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        if not math.isfinite(v):
            raise ConfigError("refused: %r is not a finite number" % v)
        s = repr(v)
        m = re.fullmatch(r"(-?\d+)(\.\d+)?e([-+])(\d+)", s)
        if m:
            s = "%s%se%s%s" % (m.group(1), m.group(2) or ".0", m.group(3), m.group(4))
        return s
    if isinstance(v, (list, tuple)):
        return "[" + ", ".join(format_value(x) for x in v) + "]"
    if isinstance(v, str):
        if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_./-]*", v) and v.lower() not in (
                "null", "true", "false", "yes", "no", "on", "off", "y", "n", "nan", "inf"):
            return v
        return json.dumps(v, ensure_ascii=False)
    raise ConfigError("refused: cannot write a value of type %s" % type(v).__name__)


def _value_span(body: str, col: int) -> tuple[int, int | None, bool]:
    """Find where the value that starts at col ends on its line, and where the line's comment starts.

    Returns:
        (end of the value text, column of the comment's '#' or None, True if brackets and quotes balance).
    """
    depth, quote, i = 0, None, col
    while i < len(body):
        ch = body[i]
        if quote:
            if ch == "\\" and quote == '"':
                i += 2
                continue
            if ch == quote:
                if quote == "'" and body[i + 1:i + 2] == "'":
                    i += 2
                    continue
                quote = None
        elif ch in "'\"" and (i == col or body[:i].rstrip()[-1:] in ("[", "{", ",", ":")):
            quote = ch
        elif ch in "[{":
            depth += 1
        elif ch in "]}":
            depth -= 1
        elif ch == "#" and depth == 0 and i > col and body[i - 1] in " \t":
            break
        i += 1
    text = body[col:i].rstrip()
    return col + len(text), (i if i < len(body) else None), depth == 0 and quote is None


def _replaced(tree: Any, keys: list[str], value: Any) -> Any:
    out = dict(tree)
    out[keys[0]] = value if len(keys) == 1 else _replaced(tree[keys[0]], keys[1:], value)
    return out


def set_value(doc: ConfigDoc, dotted: str, value: Any) -> ConfigDoc:
    """Return a new ConfigDoc whose text differs from doc's only in the value text of one key.

    Args:
        doc: The open config.
        dotted: The key, e.g. 'data.error_floor_Z'.
        value: The new plain value (float, int, bool, str, None or a list of those).

    Raises:
        ConfigError: if the key is missing, its value does not sit on the key's own line (a block scalar or a
            list over several lines), or the re-parse shows any other change (never expected).
    """
    data = _parse(doc.text)
    parent, key = _locate(data, dotted)
    old = plain(parent[key])
    kline = parent.lc.key(key)[0]
    vline, vcol = parent.lc.value(key)
    lines = doc.text.splitlines(keepends=True)
    if vline != kline:
        raise ConfigError("refused: %s spans several lines; edit it in a text editor" % dotted)
    raw = lines[vline]
    body = raw.rstrip("\r\n")
    eol = raw[len(body):]
    end, cstart, balanced = _value_span(body, vcol)
    try:
        same = balanced and plain(_parse("v: " + body[vcol:end])["v"]) == old
    except Exception:
        same = False
    if not same:
        raise ConfigError("refused: the value of %s does not fit on its line (%r)" % (dotted, body[vcol:end]))
    new = format_value(value)
    if cstart is None:
        newbody = body[:vcol] + new
    else:
        newbody = body[:vcol] + new + " " * max(1, cstart - (vcol + len(new))) + body[cstart:]
    text = "".join(lines[:vline]) + newbody + eol + "".join(lines[vline + 1:])
    keys = dotted.split(".")
    want = plain(value)
    new_data = _parse(text)
    if plain(new_data) != _replaced(plain(data), keys, want):
        raise ConfigError("internal: editing %s would change other values; nothing changed" % dotted)
    if yaml.safe_load(io.StringIO(text)) != _replaced(yaml.safe_load(io.StringIO(doc.text)), keys, want):
        raise ConfigError("refused: prep's YAML parser would read %s = %s differently" % (dotted, new))
    return ConfigDoc(path=doc.path, text=text, saved_text=doc.saved_text, data=new_data)


def _resolved_root(config_dir: Path, root_value: Any) -> str:
    return os.path.normcase(os.path.normpath(os.path.join(str(config_dir), str(root_value))))


def _write_temp(text: str, target: Path) -> Path:
    tmp = target.with_name(".%s.%d.tmp.yml" % (target.stem, os.getpid()))
    with open(tmp, "w", encoding="utf-8", newline="") as fh:
        fh.write(text)
    return tmp


def validate(doc: ConfigDoc, target: str | os.PathLike) -> str | None:
    """Check doc's text with prep_vulcan.py's own load_config, as if it were saved at target.

    The text is written to a temporary file next to target (paths.root is relative to the config file),
    loaded by prep and deleted again; target itself is never touched.

    Returns:
        None if prep accepts the config, else prep's message verbatim.
    """
    tmp = _write_temp(doc.text, local_path(target))
    try:
        prep_api.load_config(tmp)
        return None
    except prep_api.PrepFailure as e:
        return str(e)
    finally:
        tmp.unlink(missing_ok=True)


def save_as(doc: ConfigDoc, target: str | os.PathLike) -> ConfigDoc:
    """Save the config under a new name; the open file and existing files are never overwritten.

    name becomes the target's stem and paths.run_dir becomes mesh/<stem>, so prep's default output folder is
    new too. prep's load_config must accept the text at the target's place before the file appears.

    Returns:
        The saved ConfigDoc (path = target, not dirty).

    Raises:
        ConfigError: if the target exists, is not a .yml file, would move paths.root, or prep refuses it.
    """
    t = local_path(target)
    if t.suffix.lower() not in (".yml", ".yaml"):
        raise ConfigError("refused: %s: a config is a .yml file" % t.name)
    if t.exists():
        raise ConfigError("refused: %s exists; Save as never overwrites a file, choose a new name" % t)
    if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_.-]*", t.stem):
        raise ConfigError("refused: %r: use letters, digits, '_', '-' and '.' in the name" % t.stem)
    root = doc.get("paths.root")
    if _resolved_root(t.parent, root) != _resolved_root(doc.path.parent, root):
        raise ConfigError("refused: from %s, paths.root %r would point to %s instead of %s; save next to %s"
                          % (t.parent, root, _resolved_root(t.parent, root),
                             _resolved_root(doc.path.parent, root), doc.path.name))
    doc = set_value(set_value(doc, "name", t.stem), "paths.run_dir", "mesh/" + t.stem)
    tmp = _write_temp(doc.text, t)
    try:
        prep_api.load_config(tmp)
        if t.exists():
            raise ConfigError("refused: %s appeared while saving; nothing was overwritten" % t)
        os.replace(tmp, t)
    except prep_api.PrepFailure as e:
        raise ConfigError("prep_vulcan.py refuses this config, nothing saved: %s" % e) from None
    finally:
        tmp.unlink(missing_ok=True)
    return ConfigDoc(path=t, text=doc.text, saved_text=doc.text, data=_parse(doc.text))
