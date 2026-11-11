#!/usr/bin/env python3
"""Generate the per-game rules database from the proton launcher's own tables.

Usage: appcompat/extract.py [--proton PATH] [--output PATH] [--check PATH]

On macOS, Steam is the Windows client inside the prefix and starts games itself, so the launcher is
not there to apply its per-game settings. This script asks the launcher what it would do for every
app id it names: it loads `proton` as a module, runs its session set-up once per app id with the
macOS code paths on, and records how the environment differs from an app it knows nothing about.
Wine reads the result at process start (dlls/ntdll/unix/env.c) and applies the section of the game
that is starting.

Nothing is parsed out of the launcher's source, so a change to its tables, whatever its shape, is
picked up by running this again. --check compares a fresh result with an existing file and exits 1
when they differ.

The file is the format of MetalSharp Wine's .metalsharp/launch.env, in sections:

    [*]                 for every program Steam starts
    [1245620]           for one app id (the comment after it is the launcher's own)
    NAME=value          set NAME, unless the program's environment already has it
    NAME+=value         add value to NAME's semicolon-separated list
    # ...               a note; `# option:` and `# fex:` lines record what Wine does not apply yet

@FILES@ in a value stands for the distribution's files directory.
"""
import argparse
import ast
import importlib.machinery
import importlib.util
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

# Variables that describe one launch, not the game: set by the launcher for its own process tree.
PER_LAUNCH = {
    "WINEPREFIX", "FEX_APP_CONFIG", "FEX_APP_CONFIG_LOCATION", "WINE_GST_REGISTRY_DIR", "PATH",
    "SteamGameId", "SteamAppId", "STEAM_COMPAT_APP_ID", "STEAM_COMPAT_DATA_PATH", "HOME", "PROTON_STATE_DIR",
}
# An app id the launcher has no rules for: what it sets for it is what it sets for every game.
UNKNOWN_APP = "1"


def load_launcher(path):
    sys.path.insert(0, os.path.dirname(os.path.abspath(path)))
    sys.dont_write_bytecode = True
    loader = importlib.machinery.SourceFileLoader("proton_launcher", path)
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    # the rules are for macOS on Apple Silicon, wherever this runs
    module.IS_DARWIN = True
    platform.machine = lambda: "arm64"
    module.log = lambda msg: None
    return module


def app_ids(path):
    """Every app id the launcher names, with the comment that follows its first mention."""
    source = open(path).read()
    ids = set()
    for node in ast.walk(ast.parse(source)):
        if isinstance(node, ast.Constant) and isinstance(node.value, str) and re.fullmatch(r"[1-9]\d{1,7}", node.value):
            ids.add(node.value)
    names = {}
    for line in source.splitlines():
        m = re.match(r'\s*"(\d{2,8})"\s*[,:\]]?.*?#\s*(.+?)\s*$', line)
        if m and m.group(1) not in names:
            names[m.group(1)] = m.group(2)
    return sorted(ids, key=int), names


def session_for(launcher, appid, work):
    """The launcher's view of one app: environment, options, command line additions, FEX overrides."""
    compat = os.path.join(work, "compat")
    dist = os.path.join(work, "dist")
    os.makedirs(compat, exist_ok=True)
    os.makedirs(os.path.join(dist, "files"), exist_ok=True)
    base = {
        "HOME": work, "PATH": "/usr/bin:/bin", "PROTON_STATE_DIR": os.path.join(work, "state"),
        "STEAM_COMPAT_DATA_PATH": compat,
    }
    if appid is not None:
        base.update({"SteamGameId": appid, "SteamAppId": appid, "STEAM_COMPAT_APP_ID": appid})
    os.environ.clear()
    os.environ.update(base)

    launcher.g_proton = launcher.Proton(dist)
    launcher.g_compatdata = launcher.CompatData(compat)
    session = launcher.g_session = launcher.Session()
    session.init_wine()
    session.init_session(False)

    # paths into the distribution are written relative to it; Wine puts its own location back
    files = os.path.join(dist, "files")
    env = {k: v.replace(files, "@FILES@") for k, v in session.env.items()
           if k not in PER_LAUNCH and base.get(k) != v}
    env = {k: v for k, v in env.items() if work not in v}
    fex = {}
    try:
        with open(launcher.g_compatdata.fex_config_file) as f:
            fex = json.load(f).get("AppOverrides", {})
        os.remove(launcher.g_compatdata.fex_config_file)
    except (OSError, ValueError):
        pass
    return dict(env=env, options=set(session.compat_config), cmdline=list(session.cmdlineappend), fex=fex)


def overrides(value):
    return [item for item in (value or "").split(";") if item]


def section(view, baseline=None):
    """The lines of one section: `view` as it differs from `baseline`."""
    lines = []
    base_env = baseline["env"] if baseline else {}
    for name in sorted(view["env"]):
        value = view["env"][name]
        if name == "WINEDLLOVERRIDES":
            added = [item for item in overrides(value) if item not in overrides(base_env.get(name))]
            if added:
                lines.append("WINEDLLOVERRIDES+=" + ";".join(added))
            for item in overrides(base_env.get(name)):
                if item not in overrides(value):
                    lines.append("# without the override every game gets: " + item)
        elif base_env.get(name) != value:
            lines.append(f"{name}={value}")
    for name in sorted(base_env):
        if name not in view["env"]:
            lines.append(f"# without the variable every game gets: {name}")
    base_options = baseline["options"] if baseline else set()
    for option in sorted(view["options"] - base_options):
        lines.append("# option: " + option)
    for option in sorted(base_options - view["options"]):
        lines.append("# option off: " + option)
    for arg in view["cmdline"]:
        lines.append("# command line: " + arg)
    if view["fex"]:
        lines.append("# fex: " + json.dumps(view["fex"], sort_keys=True))
    return lines


def generate(proton_path):
    launcher = load_launcher(proton_path)
    ids, names = app_ids(proton_path)
    saved_env = dict(os.environ)
    work = tempfile.mkdtemp(prefix="appcompat-")
    try:
        baseline = session_for(launcher, UNKNOWN_APP, work)
        out = []
        try:
            version = subprocess.run(["git", "-C", ROOT, "describe", "--tags", "--always", "--", ], check=True,
                                     stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=saved_env).stdout.decode().strip()
        except (OSError, subprocess.CalledProcessError):
            version = "unknown"
        out.append("# Per-game rules for programs Steam starts, generated by appcompat/extract.py from the proton")
        out.append("# launcher's tables. Do not edit: change the launcher and generate it again.")
        out.append("#   [*] is for every program with a Steam app id, [<app id>] for one game.")
        out.append("#   NAME=value sets NAME unless the program's environment has it; NAME+=value adds to its list.")
        out.append("")
        out.append("[*]")
        out.extend(section(baseline))
        count = 0
        for appid in ids:
            lines = section(session_for(launcher, appid, work), baseline)
            if not lines:
                continue
            count += 1
            out.append("")
            out.append(f"[{appid}]" + (f"  # {names[appid]}" if appid in names else ""))
            out.extend(lines)
        return "\n".join(out) + "\n", count, len(ids)
    finally:
        os.environ.clear()
        os.environ.update(saved_env)
        shutil.rmtree(work, ignore_errors=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--proton", default=os.path.join(ROOT, "proton"))
    parser.add_argument("--output", default=os.path.join(HERE, "appcompat.env"))
    parser.add_argument("--check", metavar="PATH", help="compare with an existing file instead of writing one")
    args = parser.parse_args()

    text, count, total = generate(args.proton)
    if args.check:
        if open(args.check).read() != text:
            print(f"{args.check} is out of date: run appcompat/extract.py", file=sys.stderr)
            sys.exit(1)
        print(f"{args.check} is up to date ({count} games)")
        return
    with open(args.output, "w") as f:
        f.write(text)
    print(f"{args.output}: rules for {count} games, of {total} numbers the launcher names")


if __name__ == "__main__":
    main()
