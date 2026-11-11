"""DJ config — which folders DJ is allowed to look in, and which models to use.

Everything is stored in dj_config.json, next to dj.py. Nothing is sent
anywhere: the config lives on this laptop only.

Default folders (the user confirms or changes them on first run):
  Downloads, Desktop, Documents, Pictures, and his user-profile files
  (for example Antigravity project files under C:\\Users\\<name>\\...).
DJ never indexes the whole C: drive — Windows system files would slow
the index down and fill the results with junk.
"""

import json
import os
from pathlib import Path

# File that holds the saved settings, next to this file.
CONFIG_PATH = Path(__file__).resolve().parent / "dj_config.json"

# Folder where DJ keeps its index and logs, next to dj.py.
DATA_DIR = Path(__file__).resolve().parent / "dj_data"

# Free local models in LM Studio. The chat model understands the user
# and decides actions; the embedding model powers the vector search.
# chat_model may be "" — that means "use whatever chat model is loaded
# in LM Studio right now".
DEFAULT_CHAT_MODEL = ""
DEFAULT_EMBED_MODEL = "nomic-embed-text-v1.5"
DEFAULT_LMSTUDIO_URL = "http://localhost:1234/v1"


def find_desktop() -> Path:
    """Return the real Desktop folder.

    On this laptop the Desktop is the OneDrive Desktop — the plain
    C:\\Users\\<name>\\Desktop folder does not exist — so check OneDrive
    first, then the plain Desktop.
    """
    home = Path.home()
    onedrive_desktop = home / "OneDrive" / "Desktop"
    if onedrive_desktop.is_dir():
        return onedrive_desktop
    return home / "Desktop"


def default_folders() -> list:
    """The five folders DJ looks in by default.

    Each entry is a dict: {"path": str, "enabled": bool}. The last one is
    the user-profile folder for things like Antigravity project files —
    the user changes it on the first-run screen if his projects live
    somewhere else.
    """
    home = Path.home()
    antigravity = home / "Antigravity"
    # If there is a real Antigravity folder, use it; otherwise point at
    # the profile folder and let the user narrow it down on first run.
    user_files = antigravity if antigravity.is_dir() else home
    return [
        {"path": str(home / "Downloads"), "enabled": True},
        {"path": str(find_desktop()), "enabled": True},
        {"path": str(home / "Documents"), "enabled": True},
        {"path": str(home / "Pictures"), "enabled": True},
        {"path": str(user_files), "enabled": True},
    ]


def default_config() -> dict:
    """A fresh config, used on first run."""
    return {
        "folders": default_folders(),
        "chat_model": DEFAULT_CHAT_MODEL,
        "embed_model": DEFAULT_EMBED_MODEL,
        "lmstudio_url": DEFAULT_LMSTUDIO_URL,
    }


def load_config() -> dict:
    """Load the saved config, or return the defaults if there is none."""
    if CONFIG_PATH.is_file():
        try:
            with open(CONFIG_PATH, "r", encoding="utf-8") as f:
                saved = json.load(f)
            cfg = default_config()
            cfg.update(saved)
            return cfg
        except (json.JSONDecodeError, OSError):
            pass
    return default_config()


def save_config(config: dict) -> None:
    """Save the config next to dj.py."""
    with open(CONFIG_PATH, "w", encoding="utf-8") as f:
        json.dump(config, f, indent=2)


def enabled_folders(config: dict) -> list:
    """Return the enabled folder paths that actually exist on this machine."""
    out = []
    for entry in config.get("folders", []):
        if not entry.get("enabled", True):
            continue
        p = Path(entry["path"]).expanduser()
        if p.is_dir():
            out.append(p)
    return out


def config_exists() -> bool:
    """True if the user has saved a config before (i.e. not first run)."""
    return CONFIG_PATH.is_file()
