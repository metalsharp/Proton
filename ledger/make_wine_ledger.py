#!/usr/bin/env python3
"""Generate ledger/wine.tsv: one row per commit Valve's Wine fork carries on top of wine-11.0.

Usage: ledger/make_wine_ledger.py [path/to/wine.git]

The repository must have these refs:
  wine-11.0, wine-11.20   upstream tags
  valve                   ValveSoftware/wine proton_11.0
  metalsharp              metalsharp/MetalSharp-Wine source/wine (Wine 11.20 + MetalSharp)

Rows that already carry a hand-written disposition in an existing wine.tsv (status "done")
are kept as they are, so the script can be re-run after a new upstream tag.
"""
import collections
import csv
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", ".cache", "wine.git")
OUT = os.path.join(HERE, "wine.tsv")

BASE, UPSTREAM, VALVE, MS = "wine-11.0", "wine-11.20", "valve", "metalsharp"

# Directories that only exist to talk to Linux desktop or audio stacks.
LINUX_ONLY = (
    "dlls/winex11.drv/", "dlls/winewayland.drv/", "dlls/winepulse.drv/",
    "dlls/winealsa.drv/", "dlls/wineoss.drv/",
)
LINUX_FILES = re.compile(r"(^|/)(fsync|esync)\.[ch]$")
LINUX_SUBJECT = re.compile(
    r"\b(fsync|esync|ntsync|futex|gamescope|fshack|fs hack|fullscreen hack|wayland|winex11|x11|xinput2|xrandr|"
    r"pulse|alsa|hidraw|udev|pressure.?vessel|steamrt|steam runtime|inotify|/proc|linux)\b", re.I)

MEDIA = ("dlls/winegstreamer/", "dlls/mf", "dlls/quartz/", "dlls/qasf/", "dlls/wmvcore/", "dlls/winedmo/",
         "dlls/amstream/", "dlls/msdmo/", "dlls/evr/", "dlls/mp3dmod/", "dlls/qedit/", "dlls/wmp/",
         "dlls/msvfw32/", "dlls/dsdmo/", "dlls/wmadmod/", "dlls/wmvdecod/", "dlls/msmpeg2vdec/",
         "dlls/msauddecmft/", "dlls/colorcnv/", "dlls/resampledmo/", "dlls/ir50_32/", "dlls/windows.media")
GRAPHICS = ("dlls/winevulkan/", "dlls/wined3d/", "dlls/d3d", "dlls/dxgi/", "dlls/ddraw/", "dlls/opengl32/",
            "dlls/win32u/vulkan", "dlls/win32u/opengl", "dlls/win32u/d3dkmt", "dlls/dxcore/", "dlls/dcomp/",
            "dlls/amd_ags", "dlls/atiadlxx/", "dlls/nvcuda/", "dlls/nvapi", "dlls/amdxc", "dlls/vulkan-1/",
            "libs/vkd3d/", "dlls/dxva2/", "dlls/gameux/")
INPUT = ("dlls/winebus.sys/", "dlls/dinput", "dlls/xinput", "dlls/hid", "dlls/windows.gaming.input/",
         "dlls/winexinput.sys/", "dlls/mouhid.sys/", "dlls/winehid.sys/", "dlls/joy.cpl/", "dlls/hidclass.sys/",
         "dlls/hidparse.sys/", "dlls/gameinput/")
STEAM_SUBJECT = re.compile(r"steam|lsteamclient|proton|openvr|vrclient|battleye|easyanticheat|\beac\b|anti.?cheat", re.I)
STEAM_DIFF = re.compile(
    r"SteamGameId|SteamAppId|STEAM_COMPAT|steamclient|lsteamclient|PROTON_[A-Z]|BattlEye|easyanticheat|"
    r"gameoverlayrenderer", re.I)
ANTICHEAT = re.compile(r"battleye|easyanticheat|PROTON_EAC|PROTON_BATTLEYE|anti.?cheat|belauncher", re.I)
PICK = re.compile(r"cherry picked from commit ([0-9a-f]{7,40})")

csv.field_size_limit(10 ** 9)


def git(*args):
    return subprocess.run(("git", "-C", REPO) + args, check=True, stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL).stdout.decode("utf-8", "replace")


def patch_ids(rng):
    log = subprocess.Popen(("git", "-C", REPO, "log", "-p", "--no-merges", rng), stdout=subprocess.PIPE)
    out = subprocess.run(("git", "patch-id", "--stable"), stdin=log.stdout, stdout=subprocess.PIPE,
                         check=True).stdout.decode()
    log.wait()
    return dict(reversed(line.split()) for line in out.splitlines())  # commit -> patch id


def commits(rng):
    """Oldest first: sha, date, author, subject, body, files, added lines."""
    meta = git("log", "--reverse", "--no-merges", "--date=short",
               "--format=%x01%H%x02%ad%x02%an%x02%s%x02%b%x03", "--name-only", rng)
    rows = []
    for chunk in meta.split("\x01")[1:]:
        head, _, tail = chunk.partition("\x03")
        sha, date, author, subject, body = head.split("\x02", 4)
        files = [f for f in tail.splitlines() if f.strip()]
        rows.append(dict(sha=sha, date=date, author=author, subject=subject.strip(), body=body, files=files,
                         added=""))
    by_sha = {r["sha"]: r for r in rows}
    cur, buf = None, []
    patch = subprocess.Popen(("git", "-C", REPO, "log", "--no-merges", "-p", "-U0", "--format=%x01%H", rng),
                             stdout=subprocess.PIPE)
    for raw in patch.stdout:
        line = raw.decode("utf-8", "replace")
        if line.startswith("\x01"):
            if cur:
                by_sha[cur]["added"] = "".join(buf)
            cur, buf = line[1:].strip(), []
        elif line.startswith("+") and not line.startswith("+++"):
            buf.append(line)
    if cur:
        by_sha[cur]["added"] = "".join(buf)
    patch.wait()
    return rows


def area(files):
    """The class the touched paths suggest, and whether they agree."""
    votes = collections.Counter()
    for f in files:
        if f.startswith(LINUX_ONLY) or LINUX_FILES.search(f):
            votes["L"] += 1
        elif f.startswith(MEDIA):
            votes["M"] += 1
        elif f.startswith(GRAPHICS):
            votes["G"] += 1
        elif f.startswith(INPUT):
            votes["I"] += 1
        else:
            votes["W"] += 1
    if not votes:
        return "W", False
    top = votes.most_common(1)[0][0]
    return top, len(votes) > 1


def top_dirs(files, limit=3):
    dirs = collections.Counter("/".join(f.split("/")[:2]) for f in files)
    return ", ".join(d for d, _ in dirs.most_common(limit)) + (" ..." if len(dirs) > limit else "")


def main():
    upstream_all = set(git("rev-list", UPSTREAM).split())
    up_pid = patch_ids(f"{BASE}..{UPSTREAM}")
    up_by_pid = {pid: sha for sha, pid in up_pid.items()}
    up_subjects = collections.defaultdict(list)
    for line in git("log", "--no-merges", "--format=%H%x02%an%x02%s", f"{BASE}..{UPSTREAM}").splitlines():
        sha, author, subject = line.split("\x02", 2)
        up_subjects[(author, subject.strip())].append(sha)

    ms_pid = patch_ids(f"{UPSTREAM}..{MS}")
    ms_by_pid = {pid: sha for sha, pid in ms_pid.items()}
    ms_subjects = {}
    for line in git("log", "--no-merges", "--format=%H%x02%s", f"{UPSTREAM}..{MS}").splitlines():
        sha, subject = line.split("\x02", 1)
        ms_subjects[subject.strip()] = sha

    valve_pid = patch_ids(f"{BASE}..{VALVE}")

    kept = {}
    if os.path.exists(OUT):
        with open(OUT, newline="") as f:
            for row in csv.DictReader(f, delimiter="\t"):
                if row.get("status") == "done":
                    kept[row["commit"]] = row

    fields = ["n", "commit", "date", "author", "subject", "class", "disposition", "status", "evidence",
              "anticheat", "files", "paths", "target", "note"]
    rows = []
    for n, c in enumerate(commits(f"{BASE}..{VALVE}"), 1):
        sha = c["sha"]
        if sha in kept:
            kept[sha]["n"] = n
            rows.append(kept[sha])
            continue

        cls, mixed = area(c["files"])
        disposition, status, evidence, note = "port", "review", "", ""
        pid = valve_pid.get(sha)
        picks = PICK.findall(c["body"])
        full_picks = [p for p in picks if p in upstream_all]
        subject_hits = up_subjects.get((c["author"], c["subject"]), [])

        if full_picks:
            cls, disposition, status = "U", "drop", "auto"
            evidence = "cherry-pick of upstream " + full_picks[0][:12]
        elif pid and pid in up_by_pid:
            cls, disposition, status = "U", "drop", "auto"
            evidence = "same patch as upstream " + up_by_pid[pid][:12]
        elif pid and pid in ms_by_pid:
            disposition, status = "have", "auto"
            evidence = "same patch as MetalSharp " + ms_by_pid[pid][:12]
        elif subject_hits:
            cls, disposition = "U", "drop"
            evidence = "same author and subject as upstream " + subject_hits[0][:12] + "; diff differs, confirm"
        elif c["subject"] in ms_subjects:
            disposition = "have"
            evidence = "same subject as MetalSharp " + ms_subjects[c["subject"]][:12] + "; confirm"
        elif picks:
            evidence = "cherry-pick of " + picks[0][:12] + ", which is not in " + UPSTREAM
            note = "later upstream or another tree; check whether a newer Wine already has it"

        linux_paths = bool(c["files"]) and all(
            f.startswith(LINUX_ONLY) or LINUX_FILES.search(f) for f in c["files"])
        if cls != "U" and disposition == "port":
            if linux_paths:
                cls, disposition, status = "L", "drop", "auto"
                evidence = "touches only Linux desktop or audio drivers"
            elif STEAM_SUBJECT.search(c["subject"]) or STEAM_DIFF.search(c["added"]):
                cls = "S"
            elif LINUX_SUBJECT.search(c["subject"]):
                cls = "L"
                disposition = "map-or-drop"
                evidence = "subject names a Linux mechanism; touches shared code"
            elif cls == "L":
                disposition = "map-or-drop"
                evidence = "mostly Linux desktop or audio drivers, plus shared code"
        if mixed and status == "review" and not note:
            note = "touches more than one area"

        rows.append(dict(
            n=n, commit=sha[:12], date=c["date"], author=c["author"], subject=c["subject"], **{"class": cls},
            disposition=disposition, status=status, evidence=evidence,
            anticheat="yes" if ANTICHEAT.search(c["subject"]) or ANTICHEAT.search(c["added"]) else "",
            files=len(c["files"]), paths=top_dirs(c["files"]), target="", note=note))

    with open(OUT, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields, delimiter="\t", lineterminator="\n", extrasaction="ignore")
        w.writeheader()
        w.writerows(rows)

    by = collections.Counter((r["class"], r["disposition"], r["status"]) for r in rows)
    print(f"{len(rows)} commits -> {OUT}")
    for (cls, disp, status), count in sorted(by.items()):
        print(f"  {cls}  {disp:<12} {status:<7} {count}")
    print("  anti-cheat related:", sum(1 for r in rows if r["anticheat"]))


if __name__ == "__main__":
    main()
