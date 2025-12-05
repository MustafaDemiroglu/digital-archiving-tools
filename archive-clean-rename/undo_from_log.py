#!/usr/bin/env python3
"""
undo_from_log.py

Undo/rollback changes recorded in an archive_rename log file.

It reverses:
  - RENAMED_FILE: old -> new   (moves new back to old)
  - RENAMED_DIR: old_dir -> new_dir  (renames new_dir back to old_dir)

Important:
  - The script reads the log, builds reverse steps in reverse chronological order,
    and applies them carefully checking for conflicts.
  - Dry-run mode (--dry-run / -n) only reports what would be done.
  - Use --force to overwrite existing targets (dangerous).
Usage:
  python3 undo_from_log.py /path/to/archive_rename_log_....log
  python3 undo_from_log.py /path/to/log --dry-run
"""
import argparse
import json
from pathlib import Path
import re
from datetime import datetime
import shutil

REN_DIR_RE = re.compile(r'RENAMED_DIR:\s*(.+)\s*->\s*(.+)')
REN_FILE_RE = re.compile(r'RENAMED_FILE:\s*(.+)\s*->\s*(.+)')
COPIED_RE = re.compile(r'COPIED(?:_TO_TMP|):\s*(.+)\s*->\s*(.+)')
REMOVED_OLD_RE = re.compile(r'REMOVED_OLD:\s*(.+)')
DRY_PREFIX = "DRY:"

def parse_log_actions(path: Path):
    """
    Return a list of actions in order they appear.
    Action dict example:
      {"type": "RENAMED_DIR", "from": "/old", "to": "/new", "line_no": 123}
    """
    actions = []
    with path.open(encoding="utf-8") as f:
        for i, line in enumerate(f, start=1):
            s = line.strip()
            if not s:
                continue
            body = s
            if DRY_PREFIX in s:
                # skip dry-run entries: they didn't actually run
                continue

            m = REN_DIR_RE.search(body)
            if m:
                actions.append({"type": "RENAMED_DIR", "from": m.group(1).strip(), "to": m.group(2).strip(), "line": i})
                continue
            m = REN_FILE_RE.search(body)
            if m:
                actions.append({"type": "RENAMED_FILE", "from": m.group(1).strip(), "to": m.group(2).strip(), "line": i})
                continue
            m = COPIED_RE.search(body)
            if m:
                actions.append({"type": "COPIED", "from": m.group(1).strip(), "to": m.group(2).strip(), "line": i})
                continue
            m = REMOVED_OLD_RE.search(body)
            if m:
                actions.append({"type": "REMOVED_OLD", "path": m.group(1).strip(), "line": i})
                continue
    return actions

def build_undo_plan(actions):
    """
    Build undo plan in reverse order.
    We prefer to:
      - reverse file renames first (so files are at expected paths for dir moves)
      - then reverse dir renames
    Returns two lists: file_ops, dir_ops
    """
    # reverse scan
    file_ops = []
    dir_ops = []
    for act in reversed(actions):
        if act["type"] == "RENAMED_FILE":
            # act: from (old) -> to (new), undo should move new -> old
            file_ops.append({"src": act["to"], "dst": act["from"], "line": act["line"]})
        elif act["type"] == "RENAMED_DIR":
            # dir undo: new -> old
            dir_ops.append({"src": act["to"], "dst": act["from"], "line": act["line"]})
        elif act["type"] == "COPIED":
            # copy entries: best-effort cleanup: remove copied tmp if exists
            # skip here, optional
            pass
        elif act["type"] == "REMOVED_OLD":
            # cannot undo deletion reliably
            pass
    return file_ops, dir_ops

def safe_move(src, dst, dry=False, force=False):
    srcp = Path(src)
    dstp = Path(dst)
    if not srcp.exists():
        return False, f"source missing: {src}"
    if dstp.exists():
        if force:
            # backup existing
            bak = dstp.with_suffix(dstp.suffix + f".bak_undo_{datetime.now().strftime('%Y%m%d_%H%M%S')}")
            dstp.replace(bak)
            # now move src to dst
            srcp.replace(dstp)
            return True, f"overwrote {dst} (backup at {bak})"
        else:
            return False, f"target exists, use --force to overwrite: {dst}"
    else:
        # ensure parent exists
        dstp.parent.mkdir(parents=True, exist_ok=True)
        srcp.replace(dstp)
        return True, f"moved {src} -> {dst}"

def safe_rename_dir(src, dst, dry=False, force=False):
    srcp = Path(src)
    dstp = Path(dst)
    if not srcp.exists():
        return False, f"dir missing: {src}"
    if dstp.exists():
        if force:
            # attempt move dst out of the way
            bak = dstp.with_name(dstp.name + f".bak_undo_{datetime.now().strftime('%Y%m%d_%H%M%S')}")
            dstp.replace(bak)
            srcp.replace(dstp)
            return True, f"overwrote dir {dst} (backup at {bak})"
        else:
            return False, f"target dir exists: {dst}"
    else:
        # rename
        srcp.replace(dstp)
        return True, f"renamed dir {src} -> {dst}"

def main():
    p = argparse.ArgumentParser()
    p.add_argument("logfile", help="Path to archive log file")
    p.add_argument("-n", "--dry-run", action="store_true", help="Simulate undo without changes")
    p.add_argument("--force", action="store_true", help="Allow overwriting existing targets (dangerous)")
    p.add_argument("--limit", type=int, default=0, help="Limit number of operations (0 = all)")
    args = p.parse_args()

    logfile = Path(args.logfile)
    if not logfile.exists():
        print("Log not found:", logfile)
        return

    actions = parse_log_actions(logfile)
    file_ops, dir_ops = build_undo_plan(actions)

    undo_log = logfile.parent / f"undo_{logfile.stem}_{datetime.now().strftime('%Y%m%d_%H%M%S')}.log"
    with undo_log.open("a", encoding="utf-8") as out:
        out.write(f"UNDO START {datetime.now().isoformat()} dry={args.dry_run}\n")

    # Apply file ops first
    applied = 0
    for op in file_ops:
        if args.limit and applied >= args.limit:
            break
        src, dst = op["src"], op["dst"]
        if args.dry_run:
            print("DRY: would move file:", src, "->", dst)
            with undo_log.open("a", encoding="utf-8") as out:
                out.write(f"DRY_MOVE {src} -> {dst}\n")
        else:
            ok, msg = safe_move(src, dst, dry=False, force=args.force)
            with undo_log.open("a", encoding="utf-8") as out:
                out.write(f"MOVE_RESULT {src} -> {dst} : {ok} : {msg}\n")
            print("MOVE:", src, "->", dst, msg)
        applied += 1

    # Then dir ops
    applied = 0
    for op in dir_ops:
        if args.limit and applied >= args.limit:
            break
        src, dst = op["src"], op["dst"]
        if args.dry_run:
            print("DRY: would rename dir:", src, "->", dst)
            with undo_log.open("a", encoding="utf-8") as out:
                out.write(f"DRY_RENAME_DIR {src} -> {dst}\n")
        else:
            ok, msg = safe_rename_dir(src, dst, dry=False, force=args.force)
            with undo_log.open("a", encoding="utf-8") as out:
                out.write(f"RENAME_DIR_RESULT {src} -> {dst} : {ok} : {msg}\n")
            print("RENAME DIR:", src, "->", dst, msg)
        applied += 1

    with undo_log.open("a", encoding="utf-8") as out:
        out.write(f"UNDO END {datetime.now().isoformat()}\n")

    print("UNDO finished. Log:", undo_log)

if __name__ == "__main__":
    main()
