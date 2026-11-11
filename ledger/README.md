# Ledger

One row per change this port has to account for. See `SPEC.md` §6.

## `wine.tsv`

Every commit Valve's Wine fork (`ValveSoftware/wine`, `proton_11.0`) carries on top of `wine-11.0`: 1,454 commits, linear, no merges. The target tree is MetalSharp Wine (`wine-11.20` plus 139 commits).

Regenerate:

```bash
ledger/make_wine_ledger.py
```

It expects a Wine repository at `.cache/wine.git` with the refs `wine-11.0`, `wine-11.20`, `valve` and `metalsharp` (or pass another path). Rows whose `status` is `done` are kept as written, so hand-made decisions survive a re-run.

| Column | Meaning |
|---|---|
| `class` | U already upstream, W Windows-side behaviour, S Steam and Proton integration, M media, G graphics, I input, L Linux-only |
| `disposition` | `drop`, `have` (MetalSharp already has it), `port`, `map-or-drop` (Linux mechanism in shared code: map to the macOS equivalent or drop) |
| `status` | `auto` decided by the script with hard evidence, `review` a suggestion a person has to confirm, `done` decided by hand |
| `evidence` | why the script decided what it did |
| `anticheat` | `yes` when the commit is part of EasyAntiCheat or BattlEye support |
| `applies` | from `ledger/try_apply.py`: `clean` or `conflict` when the commit is cherry-picked onto MetalSharp Wine after the ones before it. Mechanical only: nothing is compiled or reviewed |
| `target` | the commit in MetalSharp Wine once ported |

State on 2026-11-10 (Valve `e60892cc239`, MetalSharp `702b230e88d`):

| Class | Disposition | Status | Commits |
|---|---|---|---|
| U | drop | auto | 341 |
| U | drop | review | 53 |
| L | drop | auto | 77 |
| L | map-or-drop | review | 50 |
| S | port | review | 156 |
| W | port | review | 419 |
| G | port | review | 175 |
| M | port | review | 165 |
| I | port | review | 18 |

418 commits are settled automatically. 1,036 need a person; 17 of those are anti-cheat support.

Of the 933 marked `port`, 521 apply cleanly in order and 412 conflict (`ledger/try_apply.py`, same date). The 17 anti-cheat commits were ported by hand as one commit; see `docs/macos/M3-M4-AC1-STATUS.md`.

How the automatic classes are decided:

- **U, auto:** the commit has a "cherry picked from commit" trailer naming a commit that is in `wine-11.20`, or its patch id equals that of a commit in `wine-11.0..wine-11.20`.
- **U, review:** same author and subject as an upstream commit, but the diff differs. Usually a backport with adjustments.
- **L, auto:** every file it touches is in winex11, winewayland, winepulse, winealsa or wineoss, or is an fsync/esync source file.
- Everything else gets a class from the paths it touches and from Steam or Linux keywords in its subject and added lines. That class is a starting point, not a decision.

## `anticheat/`

Inventories of what anti-cheat libraries need from a host, made with `darwin/linuxhost/tools/elfinfo.py`.
