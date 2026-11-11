"""GUI smoke test — opens the real DJ window under a virtual display.

Checks that the main window builds, the first-run setup dialog appears,
and typing a query + Send runs the whole decide/search path and prints
an answer in the chat area. LM Studio is not running here, so the brain
uses its offline keyword rules and the empty index answers "could not
find anything".

Run:  xvfb-run -a python tests/test_gui_smoke.py
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

    def checks():
        try:
            tops = [w for w in root.winfo_children()
                    if isinstance(w, tk.Toplevel)]
            assert tops, "setup dialog did not appear on first run"
            print("PASS  gui smoke: main window + setup dialog appear")
            app.entry.insert(0, "find my Virun pitch")
            app._on_send()

            def check_chat():
                try:
                    text = app.chat.get("1.0", "end")
                    assert "could not find anything" in text.lower(), \
                        "no answer appeared in chat"
                    print("PASS  gui smoke: Send runs decide/search and "
                          "answers in chat")
                    print("ALL GUI SMOKE TESTS PASSED")
                    root.destroy()
                except AssertionError as e:
                    print("FAIL  gui smoke:", e)
                    root.destroy()
            root.after(4000, check_chat)
        except AssertionError as e:
            print("FAIL  gui smoke:", e)
            root.destroy()

    root.after(1500, checks)
    root.after(20000, root.destroy)  # safety: never hang
    root.mainloop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
