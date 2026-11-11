#!/usr/bin/env python3
"""Try Valve's Wine commits against MetalSharp Wine, in order, and record which apply.

Usage: ledger/try_apply.py [path/to/wine.git] [worktree dir]

Every row of ledger/wine.tsv whose disposition is "port" is cherry-picked, oldest first, onto a
scratch branch that starts at the `metalsharp` ref. A commit that applies stays on the branch, so
later commits that build on it can apply too; one that conflicts is skipped. The result goes into
the ledger's `applies` column:

    clean      applied with no conflict
    empty      applied to nothing: its change is already in the tree
    conflict   needs a person; the note names the files that conflicted

This measures mechanical applicability only. The scratch branch (`valve-applies`) is not compiled
or reviewed, and nothing on it is a port until someone has read it.
"""
import csv
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", ".cache", "wine.git")
TREE = sys.argv[2] if len(sys.argv) > 2 else os.path.join(HERE, "..", ".cache", "wine-applies")
LEDGER = os.path.join(HERE, "wine.tsv")
ENV = dict(os.environ, GIT_AUTHOR_NAME="ledger", GIT_AUTHOR_EMAIL="ledger@localhost",
           GIT_COMMITTER_NAME="ledger", GIT_COMMITTER_EMAIL="ledger@localhost")

csv.field_size_limit(10 ** 9)


def git(*args, cwd=TREE, check=True):
    return subprocess.run(("git",) + args, cwd=cwd, env=ENV, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          check=check).stdout.decode("utf-8", "replace")


def main():
    if not os.path.isdir(TREE):
        subprocess.run(["git", "-C", REPO, "worktree", "add", "-q", "-B", "valve-applies", TREE, "metalsharp"],
                       check=True, env=ENV)
    else:
        git("checkout", "-q", "-B", "valve-applies", "metalsharp")
        git("reset", "-q", "--hard", "metalsharp")

    with open(LEDGER, newline="") as f:
        reader = csv.DictReader(f, delimiter="\t")
        fields = reader.fieldnames
        rows = list(reader)
    if "applies" not in fields:
        fields.insert(fields.index("target"), "applies")

    counts = {}
    for row in rows:
        row.setdefault("applies", "")
        if row["disposition"] != "port":
            row["applies"] = ""
            continue
        result = subprocess.run(["git", "cherry-pick", "-x", "--allow-empty", "--keep-redundant-commits", row["commit"]],
                                cwd=TREE, env=ENV, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if result.returncode == 0:
            changed = git("show", "--stat", "--format=", "HEAD").strip()
            row["applies"] = "clean" if changed else "empty"
        else:
            files = [line[3:] for line in git("status", "--porcelain").splitlines()
                     if line[:2] in ("UU", "AA", "DU", "UD", "AU", "UA", "DD")]
            row["applies"] = "conflict"
            if files and "conflicts in" not in row["note"]:
                row["note"] = (row["note"] + "; " if row["note"] else "") + "conflicts in " + ", ".join(files[:4]) + \
                              (" ..." if len(files) > 4 else "")
            git("cherry-pick", "--abort", check=False)
            git("reset", "-q", "--hard", "HEAD")
        key = (row["class"], row["applies"])
        counts[key] = counts.get(key, 0) + 1

    with open(LEDGER, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields, delimiter="\t", lineterminator="\n", extrasaction="ignore")
        w.writeheader()
        w.writerows(rows)

    total = {}
    for (cls, applies), count in sorted(counts.items()):
        print(f"  {cls}  {applies:<9} {count}")
        total[applies] = total.get(applies, 0) + count
    print("  all", ", ".join(f"{k} {v}" for k, v in sorted(total.items())))
    print("scratch branch valve-applies:", git("rev-list", "--count", "metalsharp..HEAD").strip(), "commits")


if __name__ == "__main__":
    main()
