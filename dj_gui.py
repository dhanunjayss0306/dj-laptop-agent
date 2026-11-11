"""DJ window — a small Tkinter chat window. Tkinter is built into
Python on Windows, so there is nothing extra to install.

Layout:
  [status bar: LM Studio OK / not running, files indexed, Rebuild index]
  [chat area — what you asked and what DJ answered]
  [results — files DJ found, each with its own Open button]
  [type here...] [Send]

First run: a setup screen asks which folders DJ may look in, then
builds the index with a progress bar.
"""

import queue
import threading
import tkinter as tk
from tkinter import filedialog, scrolledtext, ttk
from pathlib import Path

from dj_config import (
    DATA_DIR, config_exists, enabled_folders, load_config, save_config,
)
from dj_indexer import Indexer
from dj_brain import Brain
import dj_actions as actions

APP_TITLE = "DJ — your laptop assistant"
EXAMPLES = (
    "Try these:\n"
    "  find my Virun pitch\n"
    "  open something about travel and tourism\n"
    "  summarize my Virun pitch\n"
    "  organize today's Downloads\n"
    "  open notepad"
)


class DJApp:
    """The main window."""

    def __init__(self, root: tk.Tk):
        self.root = root
        self.root.title(APP_TITLE)
        self.root.geometry("820x640")
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
        top = ttk.Frame(self.root, padding=6)
        top.pack(fill="x")
        self.status_var = tk.StringVar(value="Starting DJ...")
        ttk.Label(top, textvariable=self.status_var).pack(side="left")
        ttk.Button(top, text="Rebuild index",
                   command=self._on_rebuild).pack(side="right", padx=2)
        ttk.Button(top, text="Folders...",
                   command=self._show_setup).pack(side="right", padx=2)

        self.chat = scrolledtext.ScrolledText(
            self.root, wrap="word", state="disabled", height=18,
            font=("Segoe UI", 11))
        self.chat.pack(fill="both", expand=True, padx=8, pady=4)

        ttk.Label(self.root, text="Files DJ found:",
                  font=("Segoe UI", 10, "bold")).pack(anchor="w", padx=8)
        results_outer = ttk.Frame(self.root)
        results_outer.pack(fill="x", padx=8, pady=2)
        self.results_canvas = tk.Canvas(results_outer, height=110)
        scrollbar = ttk.Scrollbar(results_outer, orient="vertical",
                                  command=self.results_canvas.yview)
        self.results_frame = ttk.Frame(self.results_canvas)
        self.results_frame.bind(
            "<Configure>",
            lambda e: self.results_canvas.configure(
                scrollregion=self.results_canvas.bbox("all")))
        self.results_canvas.create_window((0, 0), window=self.results_frame,
                                          anchor="nw")
        self.results_canvas.configure(yscrollcommand=scrollbar.set)
        self.results_canvas.pack(side="left", fill="both", expand=True)
        scrollbar.pack(side="right", fill="y")

        bottom = ttk.Frame(self.root, padding=8)
        bottom.pack(fill="x")
        self.entry = ttk.Entry(bottom, font=("Segoe UI", 11))
        self.entry.pack(side="left", fill="x", expand=True, padx=(0, 6))
        self.entry.bind("<Return>", lambda e: self._on_send())
        self.entry.focus()
        ttk.Button(bottom, text="Send", command=self._on_send).pack(side="right")

    # -- chat helpers ------------------------------------------------------
    def _say(self, text: str, who: str = "DJ"):
        self.chat.configure(state="normal")
        self.chat.insert("end", f"{who}: {text}\n\n")
        self.chat.see("end")
        self.chat.configure(state="disabled")

    def _refresh_status(self):
        st = self.indexer.status()
        mode = "meaning search" if st["vector_ok"] else "keyword search"
        lmstudio = ("LM Studio: OK" if self.lmstudio_ok
                    else "LM Studio: not running")
        self.status_var.set(
            f"{lmstudio}  |  Files indexed: {st['files_indexed']}  |  {mode}")

    def _clear_results(self):
        for w in self.results_frame.winfo_children():
            w.destroy()

    def _show_results(self, results: list):
        self._clear_results()
        if not results:
            return
        for r in results:
            row = ttk.Frame(self.results_frame)
            row.pack(fill="x", pady=1)
            label = (f"{r['name']}  —  {r['folder']}\n"
                     f"{r.get('snippet', '')}")
            ttk.Label(row, text=label, wraplength=640,
                      justify="left").pack(side="left", fill="x", expand=True)
            ttk.Button(row, text="Open",
                       command=lambda p=r["path"]: self._on_open_file(p)
                       ).pack(side="right", padx=4)

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
        if tag == "startup":
            self.lmstudio_ok, embed_ok, stale = data
            if not self.lmstudio_ok:
                self._say("LM Studio is not running, or no model is "
                          "loaded. Open LM Studio, load your model, click "
                          "Start Server, then click 'Rebuild index'. Until "
                          "then I can still find files, but I cannot use "
                          "the AI brain.")
            elif not embed_ok:
                self._say("LM Studio is running, but the embedding model "
                          "is not loaded. Load nomic-embed-text in LM "
                          "Studio too. Search still works by keyword.")
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
            self._show_organize_preview(data)
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

    def _startup_checks(self):
        """Background: is LM Studio up, is the embedding model loaded,
        and was the index built with the current embedding format?"""
        ok = self.brain.refresh_models()
        embed_ok = self.brain.embedding_ready() if ok else False
        stale = self.indexer.index_is_stale()
        return ("startup", (ok, embed_ok, stale))

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
            self._say("Checking today's Downloads...")
            downloads = self._downloads_folder()
            self._run_thread(
                lambda: ("organize_plan",
                         actions.plan_organize(downloads)))
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

    def _show_organize_preview(self, plan: list):
        if not plan:
            self._say("Nothing to organize: no files were added to "
                      "Downloads today.")
            return
        win = tk.Toplevel(self.root)
        win.title("Organize today's Downloads — check first")
        win.geometry("640x420")
        ttk.Label(win, text=f"{len(plan)} file(s) from today. Nothing moves "
                  "until you click Yes.",
                  font=("Segoe UI", 11, "bold")).pack(padx=10, pady=8)
        text = scrolledtext.ScrolledText(win, wrap="word", font=("Segoe UI", 10))
        text.pack(fill="both", expand=True, padx=10, pady=4)
        for item in plan:
            text.insert("end", f"{item['name']}  ->  {item['folder']}\n")
        text.configure(state="disabled")
        btns = ttk.Frame(win, padding=8)
        btns.pack(fill="x")
        ttk.Button(btns, text="Yes, move these",
                   command=lambda: self._do_organize(win, plan)).pack(
                       side="left", padx=4)
        ttk.Button(btns, text="No, cancel",
                   command=lambda: (win.destroy(),
                                    self._say("OK, nothing was moved."))
                   ).pack(side="left", padx=4)

    def _do_organize(self, win, plan: list):
        win.destroy()
        self._say("Moving the files...")
        downloads = self._downloads_folder()
        self._run_thread(
            lambda: ("organize_done",
                     actions.apply_organize(plan, downloads)))

    # -- rebuild index ---------------------------------------------------------
    def _on_rebuild(self):
        folders = enabled_folders(self.config)
        if not folders:
            self._say("No folders are turned on. Click 'Folders...' and "
                      "pick at least one folder.")
            return
        win = tk.Toplevel(self.root)
        win.title("Building the index")
        win.geometry("420x140")
        self._rebuild_win = win
        label = ttk.Label(win, text="Starting...", wraplength=380)
        label.pack(padx=12, pady=10)
        bar = ttk.Progressbar(win, length=360, mode="determinate")
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
        win = tk.Toplevel(self.root)
        win.title("DJ setup — which folders may I look in?")
        win.geometry("640x430")
        ttk.Label(win,
                  text="DJ only looks in the folders below. It never looks "
                       "in the whole C: drive.\n"
                       "Change a folder if your files live somewhere else, "
                       "then click 'Save and build index'.",
                  wraplength=600).pack(padx=10, pady=8)
        rows = []
        for entry in self.config.get("folders", []):
            row = ttk.Frame(win)
            row.pack(fill="x", padx=10, pady=3)
            var = tk.BooleanVar(value=entry.get("enabled", True))
            ttk.Checkbutton(row, variable=var).pack(side="left")
            path_var = tk.StringVar(value=entry["path"])
            ttk.Entry(row, textvariable=path_var, width=56).pack(
                side="left", fill="x", expand=True, padx=4)
            ttk.Button(row, text="Browse...",
                       command=lambda v=path_var: v.set(
                           filedialog.askdirectory() or v.get())
                       ).pack(side="left")
            rows.append((var, path_var))
        ttk.Label(win,
                  text="Tip: if your Antigravity projects live in a folder "
                       "of their own, change the last line to that folder.",
                  wraplength=600).pack(padx=10, pady=6)

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

        ttk.Button(win, text="Save and build index", command=save).pack(pady=10)


def main():
    root = tk.Tk()
    # Use the native Windows look when available.
    try:
        style = ttk.Style()
        if "vista" in style.theme_names():
            style.theme_use("vista")
    except Exception:
        pass
    DJApp(root)
    root.mainloop()


if __name__ == "__main__":
    main()
