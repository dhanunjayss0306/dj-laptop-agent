"""Run every DJ test and report PASS/FAIL.

Run:  python tests/run_tests.py
(Use the venv python on the VM: .venv-test/bin/python tests/run_tests.py)

Also checks that every DJ module compiles and imports cleanly.
Note: the GUI window itself is NOT opened here — there is no screen
on this VM. The GUI is checked by compiling it and importing it.
"""

import py_compile
import sys
import traceback
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(HERE))


def main():
    overall = True

    # 1. Every module compiles.
    for name in ["dj.py", "dj_config.py", "dj_indexer.py", "dj_brain.py",
                 "dj_lmstudio.py", "dj_theme.py", "dj_actions.py",
                 "dj_gui.py"]:
        try:
            py_compile.compile(str(ROOT / name), doraise=True)
            print(f"PASS  compile {name}")
        except Exception:
            overall = False
            print(f"FAIL  compile {name}")
            traceback.print_exc()

    # 2. Every module imports (the GUI import does NOT open a window).
    for mod in ["dj_config", "dj_indexer", "dj_brain", "dj_lmstudio",
                "dj_theme", "dj_actions", "dj_gui"]:
        try:
            __import__(mod)
            print(f"PASS  import {mod}")
        except Exception:
            overall = False
            print(f"FAIL  import {mod}")
            traceback.print_exc()

    # 3. The test suites.
    import test_indexer
    import test_brain_mock
    import test_organize
    import test_lmstudio
    import test_duplicates
    for suite in [test_indexer, test_brain_mock, test_organize,
                  test_lmstudio, test_duplicates]:
        try:
            rc = suite.main()
            print(f"{'PASS' if rc == 0 else 'FAIL'}  suite {suite.__name__}")
            overall = overall and rc == 0
        except Exception:
            overall = False
            print(f"FAIL  suite {suite.__name__} raised an exception")
            traceback.print_exc()

    # 4. No trace of the old server in the app code or README.
    # DJ talks to LM Studio only; the old server name and port must not
    # appear in any .py, .md or .txt file (except __pycache__ / dj_data).
    # (Built from pieces so this checker file itself stays clean.)
    banned = ("olla" + "ma", "114" + "34")
    bad_files = []
    for path in ROOT.rglob("*"):
        # Only DJ's own files: skip caches, its data dir, and any venv
        # (third-party packages inside a venv may mention other tools).
        if "__pycache__" in path.parts or "dj_data" in path.parts:
            continue
        if any(part.startswith(".") for part in
               path.relative_to(ROOT).parts):
            continue
        if path.is_file() and path.suffix in (".py", ".md", ".txt"):
            try:
                text = path.read_text(encoding="utf-8", errors="ignore")
            except OSError:
                continue
            if any(b in text.lower() for b in banned):
                bad_files.append(str(path.relative_to(ROOT)))
    if bad_files:
        overall = False
        print(f"FAIL  forbidden strings in: {', '.join(bad_files)}")
    else:
        print("PASS  no forbidden server strings in app code or README")

    print("\n" + ("=" * 50))
    print("ALL TESTS PASSED" if overall else "SOME TESTS FAILED")
    print("=" * 50)
    return 0 if overall else 1


if __name__ == "__main__":
    raise SystemExit(main())
