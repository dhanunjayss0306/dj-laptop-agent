"""DJ window — a small Tkinter chat window. Tkinter is built into
Python on Windows, so there is nothing extra to install.

Look: Astryx neutral theme tokens (see dj_theme.py) — flat white
cards on a light-grey body, Astryx blue #0074e2 for the main buttons,
clear message rows (your messages on light blue, DJ's on white).
Flat only: no gradients, no glow, no emoji icons.

Layout:
  [status bar: LM Studio OK / not running, files indexed, Rebuild index]
  [chat area — what you asked and what DJ answered]
  [results — files DJ found, each in its own card with an Open button]
  [type here...] [Send]

First run: a setup screen asks which folders DJ may look in, then
builds the index with a progress bar.
"""

import queue
import threading
import tkinter as tk
from tkinter import filedialog, scrolledtext, ttk
from pathlib import Path

import dj_theme as theme
from dj_config import (
    DATA_DIR, config_exists, enabled_folders, load_config, save_config,
)
from dj_indexer import Indexer
from dj_brain import Brain
import dj_actions as actions
import dj_lmstudio

APP_TITLE = "DJ — your laptop assistant"
EXAMPLES = (
    "Try these:\n"
    "  find my Virun pitch\n"
    "  open something about travel and tourism\n"
    "  summarize my Virun pitch\n"
    "  organize yesterday's Downloads\n"
    "  find duplicates\n"
    "  open notepad"
)

ORGANIZE_RANGES = [
    ("Today", ("today", None)),
    ("Yesterday", ("yesterday", None)),
    ("Last 7 days", ("last_days", 7)),
    ("All files", ("all", None)),
]


class DJApp:
    """The main window."""

    def __init__(self, root: tk.Tk):
        self.root = root
        self.root.title(APP_TITLE)
        self.root.geometry("880x720")
        self.config = load_config()
        self.data_dir = DATA_DIR
        self.data_dir.mkdir(parents=True, exist_ok=True)
        self.indexer = Indexer(self.data_dir, self.config["lmstudio_url"],
                               self.config["embed_model"])
        self.indexer.load_keyword_index()
        self.brain = Brain(self.config["lmstudio_url"],
                           self.config.get("chat_model", ""),
                           self.config["embed_model"])
        self.lmstudio_ok = False
        self._job_queue = queue.Queue()
        self._rebuild_win = None
        self._rebuild_label = None
        self._rebuild_bar = None
        # Progress updates from the worker thread land here as plain
        # data; the main thread paints them (Tkinter must only ever
        # be touched from the main thread).
        self._progress_state = None
        # Duplicate groups currently shown, and their checkboxes:
        # [(BooleanVar, path, group_index)].
        self._dup_vars = []
        self._build_ui()
        self._say("Hi, I am DJ. I run only on this laptop — nothing "
                  "leaves it, and I never move or delete anything "
                  "without asking you first.")
        self._say(EXAMPLES)
        # Poll the job queue forever (cheap, every 200 ms); background
        # jobs drop their results in the queue and the main thread
        # picks them up here, so Tkinter is only ever touched from
        # the main thread.
        self.root.after(200, self._check_jobs)
        # First run: ask which folders to use. Otherwise check LM Studio
        # in the background and show the index status.
        if not config_exists():
            self.root.after(300, self._show_setup)
        else:
            self._refresh_status()
            self._run_thread(self._startup_checks)

    # -- UI construction ------------------------------------------------
    def _build_ui(self):
        # Status bar: white strip with a thin border under it.
        bar = tk.Frame(self.root, bg=theme.BG_SURFACE, height=36)
        bar.pack(fill="x")
        self.status_var = tk.StringVar(value="Starting DJ...")
        self.status_label = tk.Label(bar, textvariable=self.status_var,
                                     bg=theme.BG_SURFACE,
                                     fg=theme.TEXT_PRIMARY,
                                     font=theme.FONT_BODY)
        self.status_label.pack(side="left", padx=10, pady=6)
        theme.flat_button(bar, text="Rebuild index",
                          command=self._on_rebuild).pack(side="right",
                                                         padx=4, pady=4)
        theme.flat_button(bar, text="Folders...",
                          command=self._show_setup).pack(side="right",
                                                         padx=4, pady=4)
        tk.Frame(self.root, bg=theme.BORDER, height=1).pack(fill="x")

        self.chat = scrolledtext.ScrolledText(
            self.root, wrap="word", state="disabled", height=18,
            font=theme.FONT_BODY, bg=theme.BG_SURFACE,
            fg=theme.TEXT_PRIMARY, relief="flat", borderwidth=0,
            padx=6, pady=6)
        self.chat.pack(fill="both", expand=True, padx=8, pady=4)
        self.chat.tag_config("you", background=theme.ACCENT_LIGHT,
                             foreground=theme.TEXT_PRIMARY,
                             lmargin1=10, lmargin2=10, rmargin=8,
                             spacing1=4, spacing3=6)
        self.chat.tag_config("you_label", background=theme.ACCENT_LIGHT,
                             foreground=theme.TEXT_PRIMARY,
                             font=theme.FONT_SMALL_BOLD)
        self.chat.tag_config("dj", background=theme.BG_SURFACE,
                             foreground=theme.TEXT_PRIMARY,
                             lmargin1=8, lmargin2=8, rmargin=8,
                             spacing1=4, spacing3=6)
        self.chat.tag_config("dj_label", background=theme.BG_SURFACE,
                             foreground=theme.ACCENT_HOVER,
                             font=theme.FONT_SMALL_BOLD)

        tk.Label(self.root, text="Files DJ found:",
                 bg=theme.BG_BODY, fg=theme.TEXT_PRIMARY,
                 font=theme.FONT_SECTION).pack(anchor="w", padx=10)
        results_outer = tk.Frame(self.root, bg=theme.BG_BODY)
        results_outer.pack(fill="x", padx=8, pady=2)
        self.results_canvas = tk.Canvas(results_outer, height=180,
                                        bg=theme.BG_BODY,
                                        highlightthickness=0)
        scrollbar = ttk.Scrollbar(results_outer, orient="vertical",
                                  command=self.results_canvas.yview,
                                  style="Vertical.TScrollbar")
        self.results_frame = tk.Frame(self.results_canvas, bg=theme.BG_BODY)
        self.results_frame.bind(
            "<Configure>",
            lambda e: self.results_canvas.configure(
                scrollregion=self.results_canvas.bbox("all")))
        self._results_window = self.results_canvas.create_window(
            (0, 0), window=self.results_frame, anchor="nw")
        # Keep the cards as wide as the canvas, so they look like
        # full-width rows instead of narrow boxes.
        self.results_canvas.bind(
            "<Configure>",
            lambda e: self.results_canvas.itemconfig(
                self._results_window, width=e.width))
        self.results_canvas.configure(yscrollcommand=scrollbar.set)
        self.results_canvas.pack(side="left", fill="both", expand=True)
        scrollbar.pack(side="right", fill="y")

        bottom = tk.Frame(self.root, bg=theme.BG_BODY)
        bottom.pack(fill="x", padx=8, pady=8)
        self.entry = ttk.Entry(bottom, font=theme.FONT_BODY)
        self.entry.pack(side="left", fill="x", expand=True, padx=(0, 6))
        self.entry.bind("<Return>", lambda e: self._on_send())
        self.entry.focus()
        theme.flat_button(bottom, text="Send", command=self._on_send,
                          kind="primary").pack(side="right")

    # -- chat helpers ------------------------------------------------------
    def _say(self, text: str, who: str = "DJ"):
        self.chat.configure(state="normal")
        if who == "You":
            self.chat.insert("end", "You  ", "you_label")
            self.chat.insert("end", text + "\n", "you")
        else:
            self.chat.insert("end", "DJ  ", "dj_label")
            self.chat.insert("end", text + "\n", "dj")
        self.chat.insert("end", "\n")
        self.chat.see("end")
        self.chat.configure(state="disabled")

    def _set_status(self, text: str, state: str = "plain"):
        """Set the status bar text. state: ok (green), bad (red),
        busy (amber) or plain."""
        self.status_var.set(text)
        try:
            self.status_label.configure(
                fg={"ok": theme.SUCCESS, "bad": theme.DANGER,
                    "busy": theme.WARNING}.get(state, theme.TEXT_PRIMARY))
        except Exception:
            pass

    def _refresh_status(self):
        st = self.indexer.status()
        mode = "meaning search" if st["vector_ok"] else "keyword search"
        if self.lmstudio_ok:
            self._set_status(
                f"LM Studio: OK  |  Files indexed: {st['files_indexed']}  "
                f"|  {mode}", "ok")
        else:
            self._set_status(
                f"LM Studio: not running  |  Files indexed: "
                f"{st['files_indexed']}  |  {mode}", "bad")

    def _clear_results(self):
        self._dup_vars = []
        for w in self.results_frame.winfo_children():
            w.destroy()

    def _result_card(self, parent):
        card = tk.Frame(parent, bg=theme.BG_CARD,
                        highlightbackground=theme.BORDER,
                        highlightthickness=1)
        card.pack(fill="x", pady=3)
        return card

    def _show_results(self, results: list):
        self._clear_results()
        if not results:
            return
        for r in results:
            card = self._result_card(self.results_frame)
            left = tk.Frame(card, bg=theme.BG_CARD)
            left.pack(side="left", fill="x", expand=True,
                      padx=10, pady=8)
            tk.Label(left, text=r["name"], bg=theme.BG_CARD,
                     fg=theme.TEXT_PRIMARY, font=theme.FONT_SMALL_BOLD,
                     anchor="w").pack(fill="x")
            tk.Label(left, text=r["folder"], bg=theme.BG_CARD,
                     fg=theme.TEXT_FAINT, font=theme.FONT_SMALL,
                     anchor="w").pack(fill="x")
            if r.get("snippet"):
                tk.Label(left, text=r["snippet"], bg=theme.BG_CARD,
                         fg=theme.TEXT_SECONDARY, font=theme.FONT_SMALL,
                         anchor="w", wraplength=620,
                         justify="left").pack(fill="x")
            theme.flat_button(card, text="Open",
                              command=lambda p=r["path"]:
                              self._on_open_file(p),
                              kind="primary").pack(side="right", padx=10)

    def _on_open_file(self, path: str):
        ok, msg = actions.open_file(path)
        self._say(msg)

    # -- background jobs -----------------------------------------------------
    def _run_thread(self, fn):
        """Run fn() in a thread; its return value lands in _job_queue."""
        def wrapper():
            try:
                self._job_queue.put(("ok", fn()))
            except Exception as e:  # keep the GUI alive on any error
                self._job_queue.put(("error", str(e)))
        threading.Thread(target=wrapper, daemon=True).start()

    def _check_jobs(self):
        # Runs forever, every 200 ms, on the main thread only.
        try:
            while True:
                kind, value = self._job_queue.get_nowait()
                if kind == "ok":
                    self._job_done(value)
                else:
                    self._say(f"Something went wrong: {value}")
                    self._refresh_status()
        except queue.Empty:
            pass
        # Paint any index-build progress the worker thread reported.
        if self._progress_state is not None and self._rebuild_win is not None:
            stage, done, total, message = self._progress_state
            try:
                self._rebuild_label.configure(text=message)
                if stage == "scan":
                    # The total is unknown while scanning: keep the bar
                    # moving instead of sitting at zero.
                    self._rebuild_bar.configure(mode="indeterminate")
                    self._rebuild_bar.start(50)
                else:
                    self._rebuild_bar.stop()
                    self._rebuild_bar.configure(
                        mode="determinate",
                        maximum=max(total, 1), value=done)
            except Exception:
                pass
        self.root.after(200, self._check_jobs)

    def _job_done(self, value):
        """Handle a finished background job. Jobs return a (tag, data) tuple."""
        if not isinstance(value, tuple) or len(value) != 2:
            self._refresh_status()
            return
        tag, data = value
        if tag == "status":
            self._set_status(data, "busy")
        elif tag == "startup":
            self.lmstudio_ok, embed_ok, stale, note = data
            if not self.lmstudio_ok:
                # ensure_server already said what to do by hand.
                self._say(note)
            elif not embed_ok:
                self._say(note)
                if stale:
                    self._say("Your search index was also built with the "
                              "old embedding format. Once the embedding "
                              "model is loaded, click 'Rebuild index' so "
                              "meaning search works properly.")
            elif stale:
                self._say("Your search index was built with the old "
                          "embedding format. Rebuilding it now so meaning "
                          "search works properly.")
                self._refresh_status()
                self._on_rebuild()
                return
            self._refresh_status()
        elif tag == "decide":
            self._handle_action(data)
        elif tag == "rebuild":
            if self._rebuild_win is not None:
                try:
                    self._rebuild_win.destroy()
                except Exception:
                    pass
                self._rebuild_win = None
                self._rebuild_label = None
                self._rebuild_bar = None
                self._progress_state = None
            self._say(f"Index rebuilt: {data['files']} files, "
                      f"{data['chunks']} chunks. "
                      + ("Meaning search is ready."
                         if data["vector_ok"]
                         else "Keyword search only (no vector database)."))
            self._refresh_status()
        elif tag == "summary_text":
            self._say(data)
            self._refresh_status()
        elif tag == "organize_plan":
            plan, label = data
            self._show_organize_preview(plan, label)
        elif tag == "organize_done":
            moved, errors, log = data
            if moved:
                self._say(f"Done. Moved {len(moved)} file(s). "
                          f"Log saved as {log}")
            else:
                self._say("Nothing was moved.")
            for e in errors:
                self._say(e)
            self._refresh_status()
        elif tag == "duplicates":
            self._show_duplicates(data)
        elif tag == "duplicates_done":
            deleted, errors, log = data
            if deleted:
                self._say(f"Deleted {len(deleted)} file(s) to the "
                          f"Recycle Bin. Log saved as {log}")
            else:
                self._say("Nothing was deleted.")
            for e in errors:
                self._say(e)
            self._refresh_status()

    def _startup_checks(self):
        """Background: make sure LM Studio is up (starting it with
        `lms` if it is not), check the embedding model, and check
        whether the index was built with the current embedding format.
        """
        def note(text):
            self._job_queue.put(("ok", ("status", text)))

        ok, msg = dj_lmstudio.ensure_server(
            self.brain, self.config.get("chat_model", ""),
            self.config["embed_model"], on_status=note)
        self.lmstudio_ok = ok
        embed_ok = self.brain.embedding_ready() if ok else False
        stale = self.indexer.index_is_stale()
        return ("startup", (ok, embed_ok, stale, msg))

    # -- sending a message ------------------------------------------------
    def _on_send(self):
        text = self.entry.get().strip()
        if not text:
            return
        self.entry.delete(0, "end")
        self._say(text, who="You")
        self._clear_results()
        self._run_thread(lambda: ("decide", self.brain.decide(text)))

    def _handle_action(self, action: dict):
        kind = action.get("action", "search")
        query = action.get("query", "")
        if kind == "search":
            results = actions.search_files(self.indexer, query)
            if results:
                self._say(f"I found {len(results)} file(s) about "
                          f"'{query}'. Click Open on any of them.")
                self._show_results(results)
            else:
                self._say(f"I could not find anything about '{query}' in "
                          "the folders I look in. Try other words, or "
                          "click 'Rebuild index' if you added files.")
        elif kind == "open":
            results = actions.search_files(self.indexer, query)
            if not results:
                self._say(f"I could not find anything about '{query}'.")
                return
            self._say(f"Opening the best match for '{query}'. The others "
                      "are below if you want them.")
            self._show_results(results)
            ok, msg = actions.open_file(results[0]["path"])
            self._say(msg)
        elif kind == "summarize":
            self._say("Reading it and writing a short summary...")
            self._run_thread(
                lambda: ("summary_text",
                         actions.summarize_file(self.indexer, self.brain,
                                                query)))
        elif kind == "organize":
            spec = actions.parse_organize_range(query)
            if spec is None:
                self._show_range_picker()
                return
            self._plan_organize(spec)
        elif kind == "duplicates":
            self._say("Looking for extra copies in your folders...")
            folders = enabled_folders(self.config)
            self._run_thread(
                lambda: ("duplicates", actions.find_duplicates(folders)))
        elif kind == "open_app":
            ok, msg = actions.open_app(query)
            self._say(msg)
        elif kind == "list":
            results = actions.search_files(self.indexer, query)
            if results:
                self._say(f"Here are the files matching '{query}':")
                self._show_results(results)
            else:
                self._say(f"Nothing matched '{query}'.")
        else:
            results = actions.search_files(self.indexer, query or "")
            self._show_results(results)

    # -- organize -----------------------------------------------------------
    def _downloads_folder(self) -> Path:
        for entry in self.config.get("folders", []):
            p = Path(entry["path"])
            if p.name.lower() == "downloads" and p.is_dir():
                return p
        return Path.home() / "Downloads"

    def _plan_organize(self, spec):
        label = actions.range_label(spec)
        self._say(f"Checking {label} in Downloads...")
        downloads = self._downloads_folder()
        self._run_thread(
            lambda: ("organize_plan",
                     (actions.plan_organize(downloads, spec), label)))

    def _show_range_picker(self):
        """No date range given: ask which days to organize."""
        self._say("Which days should I organize?")
        win = tk.Toplevel(self.root, bg=theme.BG_SURFACE)
        win.title("Organize Downloads — which days?")
        win.geometry("420x260")
        tk.Label(win, text="Which days should I organize?",
                 bg=theme.BG_SURFACE, fg=theme.TEXT_PRIMARY,
                 font=theme.FONT_TITLE).pack(padx=12, pady=10)
        for label, spec in ORGANIZE_RANGES:
            theme.flat_button(win, text=label,
                              command=lambda s=spec, w=win:
                              (w.destroy(), self._plan_organize(s)),
                              kind="primary").pack(fill="x", padx=12, pady=3)
        theme.flat_button(win, text="Cancel",
                          command=lambda: (win.destroy(),
                                           self._say("OK, nothing was "
                                                     "moved."))).pack(
                                                         fill="x", padx=12,
                                                         pady=6)

    def _show_organize_preview(self, plan: list, label: str):
        if not plan:
            self._say(f"Nothing to organize: no files were added to "
                      f"Downloads {label}.")
            return
        win = tk.Toplevel(self.root, bg=theme.BG_SURFACE)
        win.title(f"Organize {label} — check first")
        win.geometry("640x420")
        tk.Label(win, text=f"{len(plan)} file(s) from {label}. Nothing "
                 "moves until you click Yes.",
                 bg=theme.BG_SURFACE, fg=theme.TEXT_PRIMARY,
                 font=theme.FONT_TITLE).pack(padx=10, pady=8)
        text = scrolledtext.ScrolledText(win, wrap="word",
                                         font=theme.FONT_BODY,
                                         bg=theme.BG_SURFACE,
                                         fg=theme.TEXT_PRIMARY,
                                         relief="flat", borderwidth=0)
        text.pack(fill="both", expand=True, padx=10, pady=4)
        for item in plan:
            text.insert("end", f"{item['name']}  ->  {item['folder']}\n")
        text.configure(state="disabled")
        btns = tk.Frame(win, bg=theme.BG_SURFACE)
        btns.pack(fill="x", padx=8, pady=8)
        theme.flat_button(btns, text="Yes, move these",
                          command=lambda: self._do_organize(win, plan),
                          kind="primary").pack(side="left", padx=4)
        theme.flat_button(btns, text="No, cancel",
                          command=lambda: (win.destroy(),
                                           self._say("OK, nothing was "
                                                     "moved."))).pack(
                                                         side="left", padx=4)

    def _do_organize(self, win, plan: list):
        win.destroy()
        self._say("Moving the files...")
        downloads = self._downloads_folder()
        self._run_thread(
            lambda: ("organize_done",
                     actions.apply_organize(plan, downloads)))

    # -- duplicates ---------------------------------------------------------
    def _show_duplicates(self, groups: list):
        self._clear_results()
        if not groups:
            self._say("No extra copies found — every file in your "
                      "folders is the only copy.")
            return
        total_extra = sum(len(g["files"]) - 1 for g in groups)
        total_wasted = sum(g["wasted"] for g in groups)
        self._say(f"I found {len(groups)} group(s) of extra copies "
                  f"({total_extra} extra file(s), "
                  f"{actions.human_size(total_wasted)}). The first "
                  "copy in each group is kept — tick the copies you "
                  "want deleted, then click 'Delete selected copies'.")
        for gi, group in enumerate(groups):
            card = self._result_card(self.results_frame)
            header = (f"{len(group['files'])} copies  ·  "
                      f"{group['size_text']} each  ·  "
                      f"{actions.human_size(group['wasted'])} extra")
            tk.Label(card, text=header, bg=theme.BG_CARD,
                     fg=theme.TEXT_PRIMARY, font=theme.FONT_SMALL_BOLD,
                     anchor="w").pack(fill="x", padx=10, pady=(8, 2))
            for fi, f in enumerate(group["files"]):
                row = tk.Frame(card, bg=theme.BG_CARD)
                row.pack(fill="x", padx=10, pady=1)
                var = tk.BooleanVar(value=(fi != 0))
                if fi == 0:
                    # The first copy is the one we keep: its box is
                    # ticked off and locked, so the last copy can
                    # never be deleted.
                    box = ttk.Checkbutton(row, variable=var,
                                          state="disabled")
                    box.pack(side="left")
                    tk.Label(row, text=f"{f['name']}  (keep)",
                             bg=theme.BG_CARD, fg=theme.TEXT_SECONDARY,
                             font=theme.FONT_SMALL).pack(side="left")
                else:
                    ttk.Checkbutton(row, variable=var).pack(side="left")
                    tk.Label(row, text=f["name"], bg=theme.BG_CARD,
                             fg=theme.TEXT_PRIMARY,
                             font=theme.FONT_SMALL).pack(side="left")
                tk.Label(row, text=f["folder"], bg=theme.BG_CARD,
                         fg=theme.TEXT_FAINT, font=theme.FONT_SMALL,
                         anchor="w").pack(side="left", fill="x",
                                          expand=True, padx=6)
                theme.flat_button(row, text="Open",
                                  command=lambda p=f["path"]:
                                  self._on_open_file(p),
                                  kind="primary").pack(side="right")
                self._dup_vars.append((var, f["path"], gi))
        theme.flat_button(self.results_frame,
                          text="Delete selected copies",
                          command=self._confirm_delete_duplicates,
                          kind="danger").pack(fill="x", pady=8)

    def _confirm_delete_duplicates(self):
        selected = [p for var, p, _gi in self._dup_vars if var.get()]
        if not selected:
            self._say("Nothing is ticked, so nothing will be deleted.")
            return
        # Never allow deleting the last copy of any group.
        remaining = {}
        for var, path, gi in self._dup_vars:
            remaining[gi] = remaining.get(gi, 0) + (0 if var.get() else 1)
        blocked = [gi for gi, left in remaining.items() if left < 1]
        if blocked:
            self._say("I cannot delete the last copy of a file. "
                      "Untick at least one copy in each group to keep.")
            return
        win = tk.Toplevel(self.root, bg=theme.BG_SURFACE)
        win.title("Delete these copies?")
        win.geometry("640x420")
        tk.Label(win, text=f"Delete {len(selected)} file(s)? They go "
                 "to the Recycle Bin, so you can still get them back.",
                 bg=theme.BG_SURFACE, fg=theme.TEXT_PRIMARY,
                 font=theme.FONT_TITLE, wraplength=600,
                 justify="left").pack(padx=10, pady=8)
        text = scrolledtext.ScrolledText(win, wrap="word",
                                         font=theme.FONT_BODY,
                                         bg=theme.BG_SURFACE,
                                         fg=theme.TEXT_PRIMARY,
                                         relief="flat", borderwidth=0)
        text.pack(fill="both", expand=True, padx=10, pady=4)
        for p in selected:
            text.insert("end", f"{Path(p).name}\n  {p}\n")
        text.configure(state="disabled")
        btns = tk.Frame(win, bg=theme.BG_SURFACE)
        btns.pack(fill="x", padx=8, pady=8)
        theme.flat_button(btns, text="Yes, delete these",
                          command=lambda: self._do_delete_duplicates(
                              win, selected),
                          kind="danger").pack(side="left", padx=4)
        theme.flat_button(btns, text="No, cancel",
                          command=lambda: (win.destroy(),
                                           self._say("OK, nothing was "
                                                     "deleted."))).pack(
                                                         side="left", padx=4)

    def _do_delete_duplicates(self, win, selected: list):
        win.destroy()
        self._say(f"Deleting {len(selected)} file(s) to the Recycle Bin...")
        downloads = self._downloads_folder()
        self._run_thread(
            lambda: ("duplicates_done",
                     actions.delete_to_recycle_bin(selected, downloads)))

    # -- rebuild index ---------------------------------------------------------
    def _on_rebuild(self):
        folders = enabled_folders(self.config)
        if not folders:
            self._say("No folders are turned on. Click 'Folders...' and "
                      "pick at least one folder.")
            return
        win = tk.Toplevel(self.root, bg=theme.BG_SURFACE)
        win.title("Building the index")
        win.geometry("420x140")
        self._rebuild_win = win
        label = tk.Label(win, text="Starting...", bg=theme.BG_SURFACE,
                         fg=theme.TEXT_PRIMARY, font=theme.FONT_BODY,
                         wraplength=380)
        label.pack(padx=12, pady=10)
        bar = ttk.Progressbar(win, length=360, mode="determinate",
                              style="Blue.Horizontal.TProgressbar")
        bar.pack(padx=12, pady=6)
        self._rebuild_label = label
        self._rebuild_bar = bar

        def progress(stage, done, total, message):
            # Called from the worker thread: only store plain data.
            # The main thread paints it in _check_jobs.
            self._progress_state = (stage, done, total, message)

        def job():
            idx = Indexer(self.data_dir, self.config["lmstudio_url"],
                          self.config["embed_model"], progress_cb=progress)
            counts = idx.build(folders)
            self.indexer = idx
            return ("rebuild", counts)

        self._run_thread(job)

    # -- first-run / folders setup ----------------------------------------------
    def _show_setup(self):
        win = tk.Toplevel(self.root, bg=theme.BG_SURFACE)
        win.title("DJ setup — which folders may I look in?")
        win.geometry("640x430")
        tk.Label(win,
                 text="DJ only looks in the folders below. It never looks "
                      "in the whole C: drive.\n"
                      "Change a folder if your files live somewhere else, "
                      "then click 'Save and build index'.",
                 bg=theme.BG_SURFACE, fg=theme.TEXT_PRIMARY,
                 font=theme.FONT_BODY, wraplength=600,
                 justify="left").pack(padx=10, pady=8)
        rows = []
        for entry in self.config.get("folders", []):
            row = tk.Frame(win, bg=theme.BG_SURFACE)
            row.pack(fill="x", padx=10, pady=3)
            var = tk.BooleanVar(value=entry.get("enabled", True))
            ttk.Checkbutton(row, variable=var).pack(side="left")
            path_var = tk.StringVar(value=entry["path"])
            ttk.Entry(row, textvariable=path_var, width=56).pack(
                side="left", fill="x", expand=True, padx=4)
            theme.flat_button(row, text="Browse...",
                              command=lambda v=path_var: v.set(
                                  filedialog.askdirectory() or v.get())
                              ).pack(side="left")
            rows.append((var, path_var))
        tk.Label(win,
                 text="Tip: if your Antigravity projects live in a folder "
                      "of their own, change the last line to that folder.",
                 bg=theme.BG_SURFACE, fg=theme.TEXT_SECONDARY,
                 font=theme.FONT_SMALL, wraplength=600,
                 justify="left").pack(padx=10, pady=6)

        def save():
            folders = []
            for var, path_var in rows:
                p = path_var.get().strip()
                if p:
                    folders.append({"path": p, "enabled": bool(var.get())})
            self.config["folders"] = folders
            save_config(self.config)
            win.destroy()
            self._say("Folders saved. Building the index now — this takes "
                      "a few minutes the first time.")
            self._on_rebuild()

        theme.flat_button(win, text="Save and build index", command=save,
                          kind="primary").pack(pady=10)


def main():
    root = tk.Tk()
    theme.apply_theme(root)
    DJApp(root)
    root.mainloop()


if __name__ == "__main__":
    main()
