"""DJ actions — the things DJ actually does on the laptop.

  * search_files   — find files by name or by what is inside them
  * open_file      — open a file with its normal Windows app
  * summarize_file — find a file, then summarize it with the local model
  * plan_organize / apply_organize — organize Downloads for a date
    range the user picks (today, yesterday, last N days, all),
    preview first, move only, never delete, never overwrite
  * find_duplicates / delete_to_recycle_bin — find extra copies of
    the same file and delete the ones the user picks, to the Windows
    Recycle Bin, only after a confirmation
  * open_app       — open an installed app by name

Organize rules are copied from the user's own script,
Organize-Downloads.ps1 (v3): keyword folders first, then file-type
folders, anything left goes to _Review. The script itself and its log
are never moved.
"""

import csv
import hashlib
import os
import re
import shutil
import subprocess
import sys
from datetime import date, timedelta
from pathlib import Path

from dj_indexer import SKIP_DIRS

try:
    from send2trash import send2trash as _send2trash
    SEND2TRASH_AVAILABLE = True
except ImportError:
    _send2trash = None
    SEND2TRASH_AVAILABLE = False

# Files bigger than this are not hashed for duplicates: hashing a
# multi-gigabyte video just to check it is slow, and exact copies of
# huge files are rare.
MAX_DUP_MB = 500
# Files read in 1 MB pieces while hashing.
HASH_CHUNK = 1024 * 1024

# --- Organize rules (copied from Organize-Downloads.ps1 v3) -------------
# Checked in this order. First match wins.
# Folders are written as tuples of parts, e.g. ("Hackathons",
# "Virun-Travel"), so they build correctly on Windows (\) and Linux (/).

KEYWORD_FOLDERS = [
    (("_Private-DoNotShare",),
     ["credentials", "recovery-codes", "recovery codes", "atlas-credentials"]),
    (("Hackathons", "SAPSS-Vishwakarma"),
     ["sapss", "saps", "vishwakarma", "smart public", "public sanitation",
      "sanitation", "toilet", "pulse box", "pulse_box"]),
    (("Hackathons", "SasyaSakhi-AgriTech"),
     ["sasyasakhi", "soilsaathi", "soil", "smart farm", "smart farming",
      "agritech", "agri", "crop", "farmer", "saiya", "sasya"]),
    (("Hackathons", "Virun-Travel"),
     ["virun", "yatra", "yatrasetu", "travel titan", "traveltitans",
      "localmate", "tourism", "tourist", "samartha", "nataraj", "hatra"]),
    (("Hackathons", "GlobalTap"),
     ["globaltap", "global tap"]),
    (("Hackathons", "Persona"),
     ["persona"]),
    (("Hackathons", "Quantum"),
     ["quantum"]),
    (("Hackathons", "HackerRank"),
     ["hackerrank", "ghost data", "hacerrank"]),
    (("Hackathons", "VRGym"),
     ["vrgym", "vr gym", "vr-gym"]),
    (("Projects", "Chaiya"),
     ["chaiya"]),
    (("Projects", "Health"),
     ["patient", "health concern"]),
    (("College",),
     ["ada", "assignment", "employee dataset", "startup summit",
      "idea presentation", "coa", "oopj", "os-lab", "os lab", "probability",
      "book list", "exam prep", "multiplexer", "demultiplexer",
      "experiment", "lab manual"]),
]

TYPE_FOLDERS = {
    "Programs": [".exe", ".msi"],
    "Movies": [".mp4", ".mkv", ".avi", ".mov", ".webm"],
    "Music": [".mp3", ".wav", ".flac", ".aac"],
    "Images": [".jpg", ".jpeg", ".png", ".gif", ".webp", ".heic", ".svg",
               ".jfif", ".bmp"],
    "Documents": [".pdf", ".docx", ".doc", ".txt", ".md"],
    "Spreadsheets": [".xlsx", ".xls", ".csv"],
    "Presentations": [".pptx", ".ppt"],
    "Code": [".py", ".js", ".ts", ".jsx", ".tsx", ".html", ".css", ".json",
             ".ipynb", ".dxf"],
    "Archives": [".zip", ".rar", ".7z", ".tar", ".gz"],
}

# Files the organizer never touches.
ORGANIZER_SKIP = {
    "organize-downloads.ps1", "_organizer_log.csv", "downloads-preview.csv",
}

ORGANIZER_LOG = "_Organizer_Log.csv"


def _destination_folder(name: str) -> tuple:
    """Where one file goes, using the same rules as the .ps1 script.

    Returns the folder as a tuple of parts, e.g. ("Hackathons",
    "Virun-Travel").
    """
    lower = name.lower()
    if lower.endswith(".env"):
        return ("_Private-DoNotShare",)
    for folder, words in KEYWORD_FOLDERS:
        for word in words:
            if word in lower:
                return folder
    if "whatsapp image" in lower:
        return ("Images", "WhatsApp")
    if "chatgpt image" in lower:
        return ("Images", "ChatGPT")
    if "screenshot" in lower:
        return ("Images",)
    ext = Path(name).suffix.lower()
    for folder, exts in TYPE_FOLDERS.items():
        if ext in exts:
            return (folder,)
    return ("_Review",)


def _free_path(dest_folder: Path, name: str) -> Path:
    """A destination path that never overwrites: adds -1, -2, ..."""
    dest = dest_folder / name
    if not dest.exists():
        return dest
    stem = Path(name).stem
    suffix = Path(name).suffix
    n = 1
    while True:
        cand = dest_folder / f"{stem}-{n}{suffix}"
        if not cand.exists():
            return cand
        n += 1


# --- search / open / summarize ------------------------------------------

def search_files(indexer, query: str, top_n: int = 8) -> list:
    """Search the index. Returns [{path, name, folder, snippet, score}]."""
    return indexer.search(query, top_n=top_n)


def open_file(path: str) -> tuple:
    """Open a file with its normal app. Returns (ok, message)."""
    p = Path(path)
    if not p.is_file():
        return False, f"I cannot find that file anymore: {path}"
    try:
        if sys.platform.startswith("win"):
            os.startfile(str(p))  # noqa: S606 - user asked to open it
        elif sys.platform == "darwin":
            subprocess.Popen(["open", str(p)])
        else:
            subprocess.Popen(["xdg-open", str(p)])
        return True, f"Opened {p.name}."
    except Exception as e:
        return False, f"I could not open {p.name}: {e}"


def summarize_file(indexer, brain, query: str) -> str:
    """Find the file the user means, then summarize it."""
    results = search_files(indexer, query, top_n=3)
    if not results:
        return f"I could not find a file about '{query}' to summarize."
    top = results[0]
    text = indexer.get_file_text(top["path"])
    summary = brain.summarize(text, top["name"])
    return f"Summary of {top['name']}:\n\n{summary}"


# --- organize: date ranges ----------------------------------------------

def parse_organize_range(text: str):
    """Parse a date range from the user's words.

    Returns one of ("today", None), ("yesterday", None),
    ("last_days", N), ("all", None) — or None if no range is mentioned.
    "last N days" means today and the N days before it, so a file
    from exactly N days ago is still included.
    """
    low = (text or "").lower()
    if re.search(r"\b(all|everything|every file)\b", low):
        return ("all", None)
    if "yesterday" in low:
        return ("yesterday", None)
    m = re.search(r"(?:last|past)\s+(\d+)\s+days?", low)
    if m:
        return ("last_days", max(1, int(m.group(1))))
    if "this week" in low or "last week" in low:
        return ("last_days", 7)
    if "today" in low:
        return ("today", None)
    return None


def range_label(spec) -> str:
    """Plain words for a range spec, for the preview window."""
    kind, n = spec
    if kind == "today":
        return "today"
    if kind == "yesterday":
        return "yesterday"
    if kind == "last_days":
        return f"the last {n} day{'s' if n != 1 else ''}"
    if kind == "all":
        return "all files"
    return "today"


def _range_dates(spec):
    """The set of dates a range covers, or None for 'all' (any date)."""
    today = date.today()
    kind, n = spec
    if kind == "today":
        return {today}
    if kind == "yesterday":
        return {today - timedelta(days=1)}
    if kind == "last_days":
        return {today - timedelta(days=i) for i in range(n + 1)}
    if kind == "all":
        return None
    return {today}


def _append_log(log_path: Path, rows: list) -> str | None:
    """Append rows to a log CSV (same columns as the organizer log).

    Returns an error message, or None on success.
    """
    try:
        write_header = not log_path.is_file()
        with open(log_path, "a", newline="", encoding="utf-8") as f:
            writer = csv.writer(f)
            if write_header:
                writer.writerow(["Name", "OldPath", "NewPath", "Date"])
            for row in rows:
                writer.writerow(row)
        return None
    except OSError as e:
        return f"Could not write the log: {e}"


# --- duplicates -----------------------------------------------------------

def human_size(n: int) -> str:
    """e.g. 2450 -> '2.4 KB', 2500000 -> '2.4 MB'."""
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return f"{n:.1f} {unit}" if unit != "B" else f"{n} B"
        n /= 1024.0
    return f"{n:.1f} GB"


def _sha256(path: Path) -> str | None:
    """SHA-256 of a file's contents, read in pieces. None on error."""
    try:
        h = hashlib.sha256()
        with open(path, "rb") as f:
            while True:
                piece = f.read(HASH_CHUNK)
                if not piece:
                    break
                h.update(piece)
        return h.hexdigest()
    except OSError:
        return None


def find_duplicates(folders: list) -> list:
    """Find extra copies of the same file in the given folders.

    Groups by size first (only sizes with 2+ files are hashed), then
    by SHA-256 of the contents — so two files with the same size but
    different contents are NOT duplicates. Empty files and files over
    MAX_DUP_MB are skipped. Returns a list of groups, biggest waste
    first:
      {"size": int, "size_text": str, "wasted": int,
       "files": [{"path", "name", "folder", "mtime"}]}
    "wasted" is the bytes the extra copies take up.
    """
    by_size = {}
    for folder in folders:
        folder = Path(folder)
        if not folder.is_dir():
            continue
        for root, dirs, files in os.walk(folder, followlinks=False,
                                         onerror=lambda e: None):
            dirs[:] = [d for d in dirs
                       if d.lower() not in SKIP_DIRS
                       and not d.startswith(".")]
            for name in files:
                if name.startswith("."):
                    continue
                if name.lower() in ORGANIZER_SKIP:
                    continue
                path = Path(root) / name
                try:
                    size = path.stat().st_size
                except OSError:
                    continue
                if size == 0 or size > MAX_DUP_MB * 1024 * 1024:
                    continue
                by_size.setdefault(size, []).append(path)
    groups = []
    for size, paths in by_size.items():
        if len(paths) < 2:
            continue
        by_hash = {}
        for path in paths:
            digest = _sha256(path)
            if digest is None:
                continue
            by_hash.setdefault(digest, []).append(path)
        for digest, dup_paths in by_hash.items():
            if len(dup_paths) < 2:
                continue
            files = []
            for p in sorted(dup_paths, key=lambda x: str(x).lower()):
                try:
                    mtime = date.fromtimestamp(p.stat().st_mtime)
                except OSError:
                    mtime = None
                files.append({
                    "path": str(p),
                    "name": p.name,
                    "folder": str(p.parent),
                    "mtime": mtime.isoformat() if mtime else "",
                })
            groups.append({
                "size": size,
                "size_text": human_size(size),
                "wasted": size * (len(files) - 1),
                "files": files,
            })
    groups.sort(key=lambda g: g["wasted"], reverse=True)
    return groups


def delete_to_recycle_bin(paths: list, log_dir) -> tuple:
    """Send files to the Windows Recycle Bin (never permanent delete).

    Returns (deleted, errors, log_path). Nothing is deleted without
    the caller confirming first — this function only does the deed.
    If the send2trash package is missing, nothing is deleted and the
    error says so plainly. Every deletion is written to
    _Organizer_Log.csv in log_dir.
    """
    log_path = Path(log_dir) / ORGANIZER_LOG
    if not SEND2TRASH_AVAILABLE or _send2trash is None:
        return [], ["The send2trash package is not installed, so I "
                    "cannot delete safely. Run: python -m pip install "
                    "send2trash — then try again."], str(log_path)
    deleted, errors = [], []
    rows = []
    for path in paths:
        p = Path(path)
        if not p.is_file():
            errors.append(f"{p.name}: already gone.")
            continue
        try:
            _send2trash(str(p))
            deleted.append(str(p))
            rows.append([p.name, str(p), "Recycle Bin (deleted)",
                         date.today().isoformat()])
        except Exception as e:
            errors.append(f"{p.name}: {e}")
    if rows:
        err = _append_log(log_path, rows)
        if err:
            errors.append(err)
    return deleted, errors, str(log_path)


# --- organize -------------------------------------------------------------

def plan_organize(downloads_dir, range_spec=None) -> list:
    """Plan a Downloads tidy-up for a date range. Moves NOTHING.

    range_spec is one of ("today", None), ("yesterday", None),
    ("last_days", N), ("all", None); None means today (the old
    behaviour). Only files directly in Downloads in that range.
    Returns a list of {name, old, new, folder}.
    """
    downloads = Path(downloads_dir)
    if not downloads.is_dir():
        return []
    spec = range_spec or ("today", None)
    dates = _range_dates(spec)
    plan = []
    for path in sorted(downloads.iterdir()):
        if not path.is_file():
            continue
        if path.name.lower() in ORGANIZER_SKIP:
            continue
        try:
            mtime = date.fromtimestamp(path.stat().st_mtime)
        except OSError:
            continue
        if dates is not None and mtime not in dates:
            continue
        folder_parts = _destination_folder(path.name)
        dest_folder = downloads.joinpath(*folder_parts)
        dest = _free_path(dest_folder, path.name)
        plan.append({
            "name": path.name,
            "old": str(path),
            "new": str(dest),
            "folder": os.sep.join(folder_parts),
        })
    return plan


def apply_organize(plan: list, downloads_dir) -> tuple:
    """Carry out a plan from plan_organize. Returns (moved, errors, log).

    Move only, never delete, never overwrite. Every move is written to
    _Organizer_Log.csv in Downloads, so it can be undone.
    """
    downloads = Path(downloads_dir)
    moved, errors = [], []
    for item in plan:
        try:
            src = Path(item["old"])
            dest = Path(item["new"])
            if not src.is_file():
                errors.append(f"{item['name']}: gone before I could move it.")
                continue
            dest.parent.mkdir(parents=True, exist_ok=True)
            # Re-check the free path at move time (never overwrite).
            dest = _free_path(dest.parent, dest.name)
            shutil.move(str(src), str(dest))
            moved.append({**item, "new": str(dest)})
        except Exception as e:
            errors.append(f"{item['name']}: {e}")
    log_path = downloads / ORGANIZER_LOG
    if moved:
        err = _append_log(log_path, [
            [item["name"], item["old"], item["new"],
             date.today().isoformat()]
            for item in moved
        ])
        if err:
            errors.append(err)
    return moved, errors, str(log_path)


# --- open app ---------------------------------------------------------------

APP_PATHS = {
    "notepad": ["notepad.exe"],
    "chrome": ["chrome.exe",
               r"C:\Program Files\Google\Chrome\Application\chrome.exe",
               r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe"],
    "calculator": ["calc.exe"],
    "paint": ["mspaint.exe"],
    "word": ["winword.exe"],
    "excel": ["excel.exe"],
    "powerpoint": ["powerpnt.exe"],
    "edge": ["msedge.exe",
             r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"],
    "vs code": ["code.exe"],
    "code": ["code.exe"],
    "spotify": ["spotify.exe"],
    "whatsapp": ["whatsapp.exe"],
    "explorer": ["explorer.exe"],
    "file explorer": ["explorer.exe"],
    "cmd": ["cmd.exe"],
    "terminal": ["wt.exe", "cmd.exe"],
}


def open_app(name: str) -> tuple:
    """Open an installed app by name. Returns (ok, message)."""
    key = name.strip().lower()
    if key == "settings" and sys.platform.startswith("win"):
        try:
            os.startfile("ms-settings:")  # noqa: S606 - user asked
            return True, "Opened Settings."
        except Exception as e:
            return False, f"I could not open Settings: {e}"
    candidates = APP_PATHS.get(key, [f"{key}.exe"])
    for cand in candidates:
        found = shutil.which(cand) or (cand if Path(cand).is_file() else None)
        if found:
            try:
                if sys.platform.startswith("win") and found.lower().endswith(".exe"):
                    os.startfile(found)  # noqa: S606 - user asked
                else:
                    subprocess.Popen([found])
                return True, f"Opened {key}."
            except Exception as e:
                return False, f"I found {key} but could not open it: {e}"
    return False, (f"I could not find an app called '{name}' on this laptop. "
                   "Try the full name, like 'Google Chrome', or open it "
                   "yourself once and tell me.")
