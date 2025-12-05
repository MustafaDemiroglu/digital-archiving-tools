#!/usr/bin/env python3
"""
profile_run.py

Run the archive_clean_and_rename.py under cProfile and print top N hotspots.

Usage:
  python3 profile_run.py --script ./archive_clean_and_rename.py --args "-n /path/to/root" --top 40

It will create a profile file: archive_profile_<timestamp>.prof
"""
import argparse
import cProfile
import pstats
import runpy
import sys
from pathlib import Path
from datetime import datetime

def main():
    p = argparse.ArgumentParser(description="Profile a python script (archive_clean_and_rename.py)")
    p.add_argument("--script", required=True, help="Path to the target script")
    p.add_argument("--args", default="", help="Arguments passed to the target script (quoted)")
    p.add_argument("--top", type=int, default=30, help="Number of top lines to show")
    args = p.parse_args()

    script_path = Path(args.script).resolve()
    if not script_path.exists():
        print("Script not found:", script_path)
        return

    # put args into sys.argv for the target script
    saved_argv = sys.argv.copy()
    sys.argv = [str(script_path)] + args.args.split()

    profname = f"archive_profile_{datetime.now().strftime('%Y%m%d_%H%M%S')}.prof"
    print(f"Profiling {script_path} -> {profname}")
    profiler = cProfile.Profile()
    try:
        profiler.enable()
        # run the script as a module by filename
        runpy.run_path(str(script_path), run_name="__main__")
        profiler.disable()
    except SystemExit:
        # target script may call sys.exit
        profiler.disable()
    except Exception as ex:
        profiler.disable()
        print("Script raised exception during profiling:", ex)

    profiler.dump_stats(profname)
    print(f"Profile saved to {profname}")

    # print textual summary
    stats = pstats.Stats(profname).strip_dirs().sort_stats("cumulative")
    stats.print_stats(args.top)

    print("\nSuggestions:")
    print("- Inspect the top cumulative functions above.")
    print("- Consider optimizing filesystem walks (use os.scandir), reduce repeated rglob calls, avoid excessive copy2 if not needed, or parallelize independent folder processing.")
    print("- For visualization: install snakeviz and run: snakeviz", profname)

    # restore argv
    sys.argv = saved_argv

if __name__ == "__main__":
    main()
