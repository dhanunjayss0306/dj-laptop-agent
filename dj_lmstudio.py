"""Start LM Studio's local server with the `lms` command-line tool.

DJ used to only *report* that LM Studio was not running. Now it tries
to start it itself, in this order:

  1. `lms server start`  — start the local server on port 1234
  2. `lms load <chat model>` — load the configured chat model, if one
     is set and none is loaded yet
  3. `lms load <embedding model>` — load the embedding model, if it
     is not loaded yet

`lms` is the command-line tool that ships with LM Studio. DJ looks
for it on PATH and in the usual Windows install folders. If `lms`
is not found, or a start/load fails, DJ says plainly what the user
must do by hand ("Open LM Studio, load your model, click Start
Server") and never pretends it worked.

Everything here runs in a background thread (the GUI stays usable),
and no console window flashes up on Windows: the child processes
are started hidden.
"""

import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

from dj_brain import Brain

# How long to wait for each step. Loading a big model (12 GB) into
# the GPU can take a couple of minutes, so `lms load` gets the most.
SERVER_START_TIMEOUT = 90
MODEL_LOAD_TIMEOUT = 300
SERVER_POLL_SECONDS = 30


def find_lms() -> str | None:
    """Where is the `lms` command? Returns a path, or None.

    Checks PATH first, then the usual Windows install folders.
    """
    for name in ("lms", "lms.exe", "lms.cmd"):
        found = shutil.which(name)
        if found:
            return found
    home = Path.home()
    local_app = os.environ.get("LOCALAPPDATA", "")
    program_files = os.environ.get("ProgramFiles", "")
    program_files_x86 = os.environ.get("ProgramFiles(x86)", "")
    candidates = [
        Path(local_app) / "LM-Studio" / "lms.exe",
        Path(local_app) / "LM-Studio" / "lms.cmd",
        Path(local_app) / "Programs" / "LM Studio" / "lms.exe",
        Path(local_app) / "Programs" / "LM-Studio" / "lms.exe",
        Path(program_files) / "LM Studio" / "lms.exe",
        Path(program_files_x86) / "LM Studio" / "lms.exe",
        home / "AppData" / "Local" / "LM-Studio" / "lms.exe",
    ]
    for cand in candidates:
        try:
            if cand.is_file():
                return str(cand)
        except OSError:
            continue
    # Last try: a shallow search inside the LM Studio install folder.
    for base in (Path(local_app) / "LM-Studio",
                 Path(local_app) / "Programs"):
        try:
            if not base.is_dir():
                continue
            for hit in base.rglob("lms.exe"):
                if hit.is_file() and len(hit.parts) - len(base.parts) <= 3:
                    return str(hit)
        except OSError:
            continue
    return None


def _hidden_startupinfo():
    """Start child processes without flashing a console window."""
    if sys.platform.startswith("win"):
        try:
            info = subprocess.STARTUPINFO()
            info.dwFlags |= subprocess.STARTF_USESHOWWINDOW
            info.wShowWindow = subprocess.SW_HIDE
            return info
        except Exception:
            return None
    return None


def _run_lms(lms_path: str, args: list, timeout: int) -> tuple:
    """Run one `lms` command. Returns (ok, combined output)."""
    try:
        proc = subprocess.run(
            [lms_path] + args,
            capture_output=True, text=True, timeout=timeout,
            startupinfo=_hidden_startupinfo(),
            creationflags=(subprocess.CREATE_NO_WINDOW
                           if sys.platform.startswith("win")
                           and hasattr(subprocess, "CREATE_NO_WINDOW")
                           else 0),
        )
        out = (proc.stdout or "") + (proc.stderr or "")
        return proc.returncode == 0, out.strip()
    except subprocess.TimeoutExpired:
        return False, f"lms {' '.join(args)} timed out after {timeout}s"
    except Exception as e:
        return False, str(e)


def ensure_server(brain, chat_model: str = "",
                  embed_model: str = "nomic-embed-text-v1.5",
                  on_status=None) -> tuple:
    """Make sure the LM Studio server is up with models loaded.

    `brain` is a dj_brain.Brain (only its ping/refresh_models/
    embedding_ready/list_models are used). Returns (ok, message):
      ok=True  — the server answers and a chat model is loaded
      ok=False — it could not be started; the message says what the
                 user must do by hand instead.

    The message is always plain English, never a stack trace.
    """
    def note(text):
        if on_status:
            try:
                on_status(text)
            except Exception:
                pass

    if brain.ping():
        note("LM Studio is running.")
        return _finish_up(brain, chat_model, embed_model, note)

    lms = find_lms()
    if not lms:
        return (False,
                "LM Studio is not running and I could not find the "
                "`lms` tool to start it. Open LM Studio, load your "
                "model, click Start Server, then click 'Rebuild "
                "index' in DJ.")

    note("LM Studio is not running — starting it now (this can take "
         "a minute)...")
    ok, out = _run_lms(lms, ["server", "start"], SERVER_START_TIMEOUT)
    if not ok:
        return (False,
                "I tried to start LM Studio but it did not work "
                f"({out[:200]}). Open LM Studio, load your model, "
                "click Start Server, then click 'Rebuild index' "
                "in DJ.")

    deadline = time.time() + SERVER_POLL_SECONDS
    while time.time() < deadline:
        if brain.ping():
            break
        time.sleep(2)
    else:
        return (False,
                "I started LM Studio but its server is not answering "
                "yet. Wait a few seconds, then click 'Rebuild index' "
                "in DJ — or open LM Studio and check the server says "
                "Running.")

    note("LM Studio server is up. Loading models...")
    return _finish_up(brain, chat_model, embed_model, note)


def _finish_up(brain, chat_model: str, embed_model: str, note) -> tuple:
    """Server is answering: make sure the models are loaded.

    Loads the configured chat model (if one is set and none is loaded
    yet) and the embedding model (if it is not loaded). Returns
    (ok, message).
    """
    loaded = brain.list_models()

    chat_loaded = any("embed" not in m.lower() for m in loaded)
    if not chat_loaded and (chat_model or "").strip():
        note(f"Loading your chat model ({chat_model})...")
        lms = find_lms()
        if lms:
            ok, out = _run_lms(lms, ["load", chat_model.strip()],
                               MODEL_LOAD_TIMEOUT)
            if ok:
                brain.refresh_models()
                loaded = brain.list_models()
                chat_loaded = any("embed" not in m.lower()
                                  for m in loaded)
            else:
                return (False,
                        "The LM Studio server is running, but I could "
                        f"not load the chat model ({out[:200]}). Open "
                        "LM Studio and load your chat model by hand, "
                        "then click 'Rebuild index' in DJ.")
        else:
            return (False,
                    "The LM Studio server is running, but no chat "
                    "model is loaded. Open LM Studio and load your "
                    "chat model by hand, then click 'Rebuild index' "
                    "in DJ.")
    if not chat_loaded:
        return (False,
                "The LM Studio server is running, but no chat model "
                "is loaded. Open LM Studio, load your chat model, "
                "then click 'Rebuild index' in DJ.")

    if not brain.embedding_ready():
        note("Loading the embedding model...")
        lms = find_lms()
        if lms:
            ok, out = _run_lms(lms, ["load", embed_model],
                               MODEL_LOAD_TIMEOUT)
            if ok:
                brain.refresh_models()
            if not brain.embedding_ready():
                return (True,
                        "LM Studio is running with your chat model, "
                        "but the embedding model did not load. Search "
                        "still works by keyword. In LM Studio, load "
                        "nomic-embed-text as well.")
        else:
            return (True,
                    "LM Studio is running with your chat model, but "
                    "the embedding model is not loaded. Search still "
                    "works by keyword. In LM Studio, load "
                    "nomic-embed-text as well.")
    return (True, "LM Studio is running with your models loaded.")
