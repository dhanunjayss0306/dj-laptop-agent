"""One-off visual check of the redesigned DJ window (not part of the
test suite): open the real window under a virtual display, show a
few chat messages, a result card and a duplicate group, then save
a screenshot to /tmp/dj-ui-check.png for a human to look at.

Run:  xvfb-run -a python tests/visual_check.py
"""

import sys
import tkinter as tk
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(ROOT))

from dj_gui import DJApp  # noqa: E402


def main():
    root = tk.Tk()
    app = DJApp(root)

    app._say("find my Virun pitch", who="You")
    app._say("I found 2 file(s) about 'Virun pitch'. Click Open on any "
             "of them.")
    app._show_results([
        {"name": "Virun_Frontend_Blueprint.pdf",
         "folder": r"C:\Users\dhanu\Downloads\Hackathons\Virun-Travel",
         "snippet": "VIRUN Complete Frontend Build Blueprint. Every page...",
         "path": r"C:\Users\dhanu\Downloads\Hackathons\Virun-Travel\Virun_Frontend_Blueprint.pdf"},
        {"name": "Virun pitch - Travel Titans.md",
         "folder": r"C:\Users\dhanu\Documents",
         "snippet": "A travel app for tourists visiting Chennai...",
         "path": r"C:\Users\dhanu\Documents\Virun pitch - Travel Titans.md"},
    ])
    app._say("I found 1 group(s) of extra copies (1 extra file(s), "
             "1.9 KB). The first copy in each group is kept.")
    app._show_duplicates([
        {"size": 1900, "size_text": "1.9 KB", "wasted": 1900,
         "files": [
             {"path": r"C:\Users\dhanu\Downloads\photo.jpg",
              "name": "photo.jpg",
              "folder": r"C:\Users\dhanu\Downloads", "mtime": "2026-11-11"},
             {"path": r"C:\Users\dhanu\Pictures\photo.jpg",
              "name": "photo.jpg",
              "folder": r"C:\Users\dhanu\Pictures", "mtime": "2026-11-10"},
         ]},
    ])

    def shot():
        # Close the first-run setup dialog if it appeared, then shoot.
        for w in root.winfo_children():
            if isinstance(w, tk.Toplevel):
                w.destroy()
        root.update()
        try:
            import mss
            with mss.MSS() as s:
                s.shot(output="/tmp/dj-ui-check.png")
            print("screenshot saved to /tmp/dj-ui-check.png")
        except Exception as e:
            print("screenshot failed:", e)
        root.destroy()

    root.after(1200, shot)
    root.after(10000, root.destroy)
    root.mainloop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
