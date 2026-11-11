"""DJ actions — the things DJ actually does on the laptop.

  * search_files   — find files by name or by what is inside them
  * open_file      — open a file with its normal Windows app
  * summarize_file — find a file, then summarize it with the local model
  * plan_organize / apply_organize — organize ONLY today's Downloads,
    preview first, move only, never delete, never overwrite
  * open_app       — open an installed app by name

Organize rules are copied from the user's own script,
Organize-Downloads.ps1 (v3): keyword folders first, then file-type
folders, anything left goes to _Review. The script itself and its log
are never moved.
"""

import csv
import os
import shutil
import subprocess
import sys
from datetime import date
from pathlib import Path

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


# --- organize -------------------------------------------------------------

def plan_organize(downloads_dir) -> list:
    """Plan today's Downloads tidy-up. Moves NOTHING.

    Only files directly in Downloads whose last-modified date is today.
    Returns a list of {name, old, new, folder}.
    """
    downloads = Path(downloads_dir)
    if not downloads.is_dir():
        return []
    today = date.today()
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
        if mtime != today:
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
    try:
        write_header = not log_path.is_file()
        with open(log_path, "a", newline="", encoding="utf-8") as f:
            writer = csv.writer(f)
            if write_header:
                writer.writerow(["Name", "OldPath", "NewPath", "Date"])
            for item in moved:
                writer.writerow([item["name"], item["old"], item["new"],
                                 date.today().isoformat()])
    except OSError as e:
        errors.append(f"Could not write the log: {e}")
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
