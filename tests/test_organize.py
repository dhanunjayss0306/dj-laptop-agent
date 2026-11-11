"""Test the organizer: plan today's Downloads, then apply the plan.

Checks (rules copied from Organize-Downloads.ps1 v3):
  - A Virun video goes to Hackathons\\Virun-Travel, not Movies.
  - A SAPSS file goes to Hackathons\\SAPSS-Vishwakarma.
  - A credentials file goes to _Private-DoNotShare.
  - A plain photo goes to Images.
  - A file from yesterday is NOT in the plan (today only).
  - apply_organize moves the files, writes _Organizer_Log.csv, and
    never overwrites: a clashing photo becomes photo-1.jpg.
  - The organizer's own files are never moved.

Run:  python tests/test_organize.py
"""

import os
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(ROOT))

import dj_actions as actions  # noqa: E402


def check(name, cond, detail=""):
    print(("PASS" if cond else "FAIL") + f"  {name}" + (f"  ({detail})" if detail else ""))
    return cond


def touch(path: Path, content: str = "x", mtime=None):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    if mtime is not None:
        os.utime(path, (mtime, mtime))


def main():
    ok = True
    tmp = Path(tempfile.mkdtemp(prefix="dj_dl_"))
    dl = tmp / "Downloads"
    dl.mkdir()

    now = time.time()
    yesterday = now - 86400
    touch(dl / "Virun pitch video.mp4", mtime=now)
    touch(dl / "SAPSS report final.pdf", mtime=now)
    touch(dl / "my credentials backup.txt", mtime=now)
    touch(dl / "photo.jpg", mtime=now)
    touch(dl / "old notes.txt", mtime=yesterday)
    touch(dl / "Organize-Downloads.ps1", mtime=now)
    touch(dl / "_Organizer_Log.csv", mtime=now)
    # A photo with the same name already in Images: the moved one must
    # be renamed, never overwritten.
    touch(dl / "Images" / "photo.jpg", content="original", mtime=now)

    plan = actions.plan_organize(dl)
    by_name = {p["name"]: p for p in plan}
    ok &= check("plan has 4 files (today only, organizer files skipped)",
                len(plan) == 4, f"got {len(plan)}: {sorted(by_name)}")
    ok &= check("Virun video -> Hackathons/Virun-Travel",
                by_name.get("Virun pitch video.mp4", {}).get("folder")
                == os.sep.join(["Hackathons", "Virun-Travel"]),
                by_name.get("Virun pitch video.mp4", {}).get("folder", ""))
    ok &= check("SAPSS report -> Hackathons/SAPSS-Vishwakarma",
                by_name.get("SAPSS report final.pdf", {}).get("folder")
                == os.sep.join(["Hackathons", "SAPSS-Vishwakarma"]))
    ok &= check("credentials file -> _Private-DoNotShare",
                by_name.get("my credentials backup.txt", {}).get("folder")
                == "_Private-DoNotShare")
    ok &= check("photo -> Images",
                by_name.get("photo.jpg", {}).get("folder") == "Images")
    ok &= check("yesterday's file is not planned",
                "old notes.txt" not in by_name)

    moved, errors, log = actions.apply_organize(plan, dl)
    ok &= check("apply moved 4 files", len(moved) == 4, f"moved={len(moved)}")
    ok &= check("apply had no errors", errors == [], str(errors))
    ok &= check("Virun video is in its folder",
                (dl / "Hackathons" / "Virun-Travel" / "Virun pitch video.mp4").is_file())
    ok &= check("clashing photo was renamed, not overwritten",
                (dl / "Images" / "photo-1.jpg").is_file()
                and (dl / "Images" / "photo.jpg").read_text() == "original")
    ok &= check("originals are gone from Downloads root",
                not (dl / "Virun pitch video.mp4").exists()
                and not (dl / "photo.jpg").exists())
    ok &= check("log CSV exists", Path(log).is_file(), log)
    log_text = Path(log).read_text(encoding="utf-8")
    ok &= check("log has all 4 moved files",
                all(n in log_text for n in [
                    "Virun pitch video.mp4", "SAPSS report final.pdf",
                    "my credentials backup.txt", "photo.jpg"]),
                log_text[:200])

    # Second run: nothing left from today to move.
    plan2 = actions.plan_organize(dl)
    ok &= check("second plan is empty (nothing left from today)",
                plan2 == [], str([p["name"] for p in plan2]))

    # ---- Date ranges (new behaviour) ------------------------------------
    tmp2 = Path(tempfile.mkdtemp(prefix="dj_dl_range_"))
    dl2 = tmp2 / "Downloads"
    dl2.mkdir()
    three_days = now - 3 * 86400
    ten_days = now - 10 * 86400
    touch(dl2 / "today file.txt", mtime=now)
    touch(dl2 / "yesterday file.txt", mtime=yesterday)
    touch(dl2 / "three days file.txt", mtime=three_days)
    touch(dl2 / "old file.txt", mtime=ten_days)

    plan_today = actions.plan_organize(dl2, ("today", None))
    ok &= check("range today: only today's file",
                [p["name"] for p in plan_today] == ["today file.txt"],
                str([p["name"] for p in plan_today]))
    plan_y = actions.plan_organize(dl2, ("yesterday", None))
    ok &= check("range yesterday: only yesterday's file",
                [p["name"] for p in plan_y] == ["yesterday file.txt"],
                str([p["name"] for p in plan_y]))
    plan_3 = actions.plan_organize(dl2, ("last_days", 3))
    ok &= check("range last 3 days: today + yesterday + 3 days ago",
                sorted(p["name"] for p in plan_3) ==
                ["three days file.txt", "today file.txt",
                 "yesterday file.txt"],
                str(sorted(p["name"] for p in plan_3)))
    plan_all = actions.plan_organize(dl2, ("all", None))
    ok &= check("range all: every file",
                len(plan_all) == 4, str([p["name"] for p in plan_all]))
    plan_default = actions.plan_organize(dl2)
    ok &= check("no range given still means today",
                [p["name"] for p in plan_default] == ["today file.txt"])

    ok &= check("parse: 'last 3 days'",
                actions.parse_organize_range(
                    "organize the last 3 days") == ("last_days", 3))
    ok &= check("parse: 'yesterday'",
                actions.parse_organize_range(
                    "organize yesterday's Downloads") == ("yesterday", None))
    ok &= check("parse: 'everything'",
                actions.parse_organize_range(
                    "organize everything in Downloads") == ("all", None))
    ok &= check("parse: 'this week' -> last 7 days",
                actions.parse_organize_range(
                    "organize this week") == ("last_days", 7))
    ok &= check("parse: no range mentioned -> None",
                actions.parse_organize_range(
                    "organize my files in Downloads") is None)
    ok &= check("range labels read plainly",
                actions.range_label(("last_days", 3)) == "the last 3 days"
                and actions.range_label(("all", None)) == "all files"
                and actions.range_label(("yesterday", None)) == "yesterday")

    print("\n" + ("ALL ORGANIZE TESTS PASSED" if ok else "ORGANIZE TESTS FAILED"))
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
