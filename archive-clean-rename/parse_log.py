#!/usr/bin/env python3
"""
parse_log.py

Parse archive_rename log files and print a clear summary.

Usage:
  python3 parse_log.py /path/to/archive_rename_log_YYYYMMDD_HHMMSS.log
  python3 parse_log.py --last        # finds latest archive_rename_log_*.log in cwd
  python3 parse_log.py logfile --json > summary.json

Outputs:
  - Human readable summary (stdout)
  - Optionally --json or --md for machine-readable output
"""
import argparse
import json
from pathlib import Path
import re
from datetime import datetime

REN_DIR_RE = re.compile(r'RENAMED_DIR:\s*(.+)\s*->\s*(.+)')
REN_FILE_RE = re.compile(r'RENAMED_FILE:\s*(.+)\s*->\s*(.+)')
COPIED_RE = re.compile(r'COPIED(?:_TO_TMP|):\s*(.+)\s*->\s*(.+)')
REMOVED_OLD_RE = re.compile(r'REMOVED_OLD:\s*(.+)')
ERROR_RE = re.compile(r'ERROR[_A-Z]*:\s*(.+)')
DRY_PREFIX = "DRY:"

def parse_log(path: Path):
    stats = {
        "start": None,
        "end": None,
        "dry_run": False,
        "renamed_dirs": [],
        "renamed_files": [],
        "copied": [],
        "removed_old": [],
        "errors": [],
        "raw_lines": 0,
    }
    with path.open(encoding="utf-8") as f:
        for line in f:
            stats["raw_lines"] += 1
            sline = line.strip()
            if not sline:
                continue
            # timestamp part may be at start
            body = sline
            # mark dry-run
            if DRY_PREFIX in sline:
                stats["dry_run"] = True
                body = sline.split(DRY_PREFIX,1)[1].strip()

            # detect timestamps like ISO at the very beginning
            mtime = None
            try:
                # optional ISO timestamp at start
                timepart = sline.split(None,1)[0]
                # not strict; ignore if fails
            except:
                timepart = None

            # patterns
            m = REN_DIR_RE.search(body)
            if m:
                old, new = m.group(1).strip(), m.group(2).strip()
                stats["renamed_dirs"].append({"from": old, "to": new})
                continue
            m = REN_FILE_RE.search(body)
            if m:
                old, new = m.group(1).strip(), m.group(2).strip()
                stats["renamed_files"].append({"from": old, "to": new})
                continue
            m = COPIED_RE.search(body)
            if m:
                src, dst = m.group(1).strip(), m.group(2).strip()
                stats["copied"].append({"from": src, "to": dst})
                continue
            m = REMOVED_OLD_RE.search(body)
            if m:
                stats["removed_old"].append(m.group(1).strip())
                continue
            m = ERROR_RE.search(body)
            if m:
                stats["errors"].append(m.group(1).strip())
                continue

    # basic summary
    stats["counts"] = {
        "dirs_renamed": len(stats["renamed_dirs"]),
        "files_renamed": len(stats["renamed_files"]),
        "copied": len(stats["copied"]),
        "removed_old": len(stats["removed_old"]),
        "errors": len(stats["errors"]),
    }
    return stats

def print_summary(stats, human=True):
    if human:
        print("=== Archive Rename Log Summary ===")
        print("Dry-run:", stats["dry_run"])
        print("Renamed directories:", stats["counts"]["dirs_renamed"])
        print("Renamed files:", stats["counts"]["files_renamed"])
        print("Copied entries:", stats["counts"]["copied"])
        print("Removed old files entries:", stats["counts"]["removed_old"])
        print("Errors:", stats["counts"]["errors"])
        if stats["counts"]["errors"]:
            print("\nErrors (sample):")
            for e in stats["errors"][:10]:
                print(" -", e)
        # show some examples
        if stats["counts"]["dirs_renamed"]:
            print("\nExamples of dir renames:")
            for item in stats["renamed_dirs"][:10]:
                print(" -", item["from"], "->", item["to"])
        if stats["counts"]["files_renamed"]:
            print("\nExamples of file renames:")
            for item in stats["renamed_files"][:10]:
                print(" -", item["from"], "->", item["to"])
    else:
        print(json.dumps(stats, indent=2, ensure_ascii=False))

def find_last_log(cwd: Path):
    logs = sorted(cwd.glob("archive_rename_log_*.log"))
    return logs[-1] if logs else None

def main():
    p = argparse.ArgumentParser()
    p.add_argument("logfile", nargs="?", help="Path to log file (or --last)")
    p.add_argument("--last", action="store_true", help="Use latest archive_rename_log_*.log in cwd")
    p.add_argument("--json", action="store_true", help="Output machine-readable JSON")
    args = p.parse_args()

    if args.last:
        path = find_last_log(Path.cwd())
        if not path:
            print("No log files found in cwd.")
            return
    else:
        if not args.logfile:
            print("Please provide a log file path or use --last")
            return
        path = Path(args.logfile)
        if not path.exists():
            print("Log file not found:", path)
            return

    stats = parse_log(path)
    if args.json:
        print(json.dumps(stats, indent=2, ensure_ascii=False))
    else:
        print_summary(stats, human=True)

if __name__ == "__main__":
    main()
