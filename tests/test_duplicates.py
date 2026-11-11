"""Test duplicate finding and deletion to the Recycle Bin.

Checks:
  - find_duplicates groups files with identical contents, even under
    different names in different folders
  - two files with the same size but different contents are NOT
    duplicates
  - empty files and files inside node_modules are never grouped
  - delete_to_recycle_bin removes only the files picked, keeps the
    first copy, and writes the deletions to _Organizer_Log.csv
  - when the send2trash package is missing, nothing is deleted and
    the error says so plainly
  - human_size formats bytes

The Recycle Bin itself is faked: the test monkeypatches
dj_actions._send2trash with a function that moves files to a temp
folder instead, so the test works on any machine.

Run:  python tests/test_duplicates.py
"""

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


def main():
    ok = True
    tmp = Path(tempfile.mkdtemp(prefix="dj_dup_"))
    root = tmp / "Files"
    (root / "a").mkdir(parents=True)
    (root / "b").mkdir(parents=True)
    (root / "node_modules" / "pkg").mkdir(parents=True)

    same = b"same contents here " * 100
    (root / "a" / "Virun pitch.pdf").write_bytes(same)
    (root / "b" / "virun-pitch-copy.pdf").write_bytes(same)
    (root / "b" / "another name.txt").write_bytes(same)
    # Same size, different contents: NOT a duplicate.
    (root / "a" / "looks same size.txt").write_bytes(b"X" * len(same))
    # Unique file.
    (root / "a" / "unique.txt").write_text("only me here")
    # Empty files: never grouped.
    (root / "a" / "empty1.txt").write_bytes(b"")
    (root / "b" / "empty2.txt").write_bytes(b"")
    # Same contents inside node_modules: never even looked at.
    (root / "node_modules" / "pkg" / "copy.pdf").write_bytes(same)

    groups = actions.find_duplicates([root])
    ok &= check("one duplicate group found", len(groups) == 1,
                f"got {len(groups)}")
    if groups:
        g = groups[0]
        names = sorted(f["name"] for f in g["files"])
        ok &= check("group has the 3 same-content files",
                    names == ["Virun pitch.pdf", "another name.txt",
                              "virun-pitch-copy.pdf"], str(names))
        ok &= check("group size is the file size",
                    g["size"] == len(same) and g["size_text"].endswith("KB"),
                    f"{g['size']} {g['size_text']}")
        ok &= check("wasted counts the 2 extra copies",
                    g["wasted"] == 2 * len(same), str(g["wasted"]))
        ok &= check("same-size different-content file is not in the group",
                    "looks same size.txt" not in names)
        ok &= check("node_modules copy is not in the group",
                    all("node_modules" not in f["path"] for f in g["files"]))

    # --- deletion: fake the Recycle Bin --------------------------------
    trash = tmp / "Trash"
    trash.mkdir()
    deleted_paths = []

    def fake_send2trash(path):
        src = Path(path)
        deleted_paths.append(str(src))
        src.replace(trash / src.name)

    real_send2trash = actions._send2trash
    real_available = actions.SEND2TRASH_AVAILABLE
    actions._send2trash = fake_send2trash
    actions.SEND2TRASH_AVAILABLE = True
    try:
        group_files = [f["path"] for f in groups[0]["files"]]
        keep, *extras = group_files
        deleted, errors, log = actions.delete_to_recycle_bin(
            extras, tmp)
        ok &= check("delete removed the 2 extra copies",
                    len(deleted) == 2, f"deleted={deleted}")
        ok &= check("delete had no errors", errors == [], str(errors))
        ok &= check("the kept copy is still there",
                    Path(keep).is_file(), keep)
        ok &= check("deleted files are in the fake trash",
                    all((trash / Path(p).name).is_file() for p in extras))
        ok &= check("log CSV exists", Path(log).is_file(), log)
        log_text = Path(log).read_text(encoding="utf-8")
        ok &= check("log says Recycle Bin for both deletions",
                    log_text.count("Recycle Bin (deleted)") == 2, log_text)
    finally:
        actions._send2trash = real_send2trash
        actions.SEND2TRASH_AVAILABLE = real_available

    # --- no send2trash package: nothing is deleted ----------------------
    actions._send2trash = None
    actions.SEND2TRASH_AVAILABLE = False
    try:
        victim = root / "a" / "unique.txt"
        deleted, errors, log = actions.delete_to_recycle_bin(
            [str(victim)], tmp)
        ok &= check("nothing deleted without send2trash",
                    deleted == [] and victim.is_file())
        ok &= check("error says plainly what is missing",
                    errors and "send2trash" in errors[0].lower(),
                    str(errors))
    finally:
        actions._send2trash = real_send2trash
        actions.SEND2TRASH_AVAILABLE = real_available

    ok &= check("human_size formats bytes",
                actions.human_size(500) == "500 B"
                and actions.human_size(2048) == "2.0 KB"
                and actions.human_size(3 * 1024 * 1024) == "3.0 MB",
                f"{actions.human_size(2048)} / "
                f"{actions.human_size(3 * 1024 * 1024)}")

    print("\n" + ("ALL DUPLICATE TESTS PASSED" if ok else "DUPLICATE TESTS FAILED"))
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
