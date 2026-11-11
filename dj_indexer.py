"""DJ indexer — DJ's private search engine over the user's files.

Two parts, working together:
  1. Vector search (ChromaDB + the free local nomic-embed-text-v1.5
     model through LM Studio's local server). Each file is split into
     chunks, each chunk is turned into an embedding (a list of numbers
     that captures what the chunk *means*), and stored locally in
     dj_data/chroma. A search for "travel and tourism" then finds files
     about travel even if those exact words are not in the file name.
     nomic-embed-text-v1.5 was trained with task prefixes — DJ sends
     "search_document: " in front of indexed chunks and "search_query: "
     in front of a search query (LM Studio's server does not add them).
     The prefixes are only sent to the model: they are never stored
     in the database or shown in the UI.
  2. Keyword search (always available). A plain index of file names and
     file text, saved as dj_data/keyword_index.json. Used when ChromaDB
     or the embedding model is not available, so search still works.

Nothing leaves the laptop: the vector database and the keyword index
are files on this machine only.
"""

import hashlib
import json
import re
import time
from pathlib import Path

import requests

# File types DJ can read text from.
READABLE_EXTS = {
    ".txt", ".md", ".py", ".js", ".ts", ".jsx", ".tsx", ".html", ".css",
    ".json", ".csv", ".log", ".pdf", ".docx",
}

# Folders DJ never walks into, even inside the folders the user picked.
SKIP_DIRS = {
    "appdata", ".git", "node_modules", "__pycache__", ".venv", "venv",
    ".cache", ".antigravity", "dj_data", "$recycle.bin", "system volume information",
}

# Files bigger than this are skipped (too big to embed usefully).
MAX_FILE_MB = 20

# Chunks of about 400 words, overlapping by 50 words so a sentence that
# straddles a boundary is not lost.
CHUNK_WORDS = 400
OVERLAP_WORDS = 50

# How much of a file's text the keyword index keeps (first 12,000 chars).
KEYWORD_TEXT_LIMIT = 12000

COLLECTION_NAME = "dj_files"

# Task prefixes nomic-embed-text-v1.5 was trained with. LM Studio's
# server does not add them, so DJ adds them when sending text to the
# model: "search_document: " for indexed chunks, "search_query: " for
# a search query. Without them retrieval gets worse, silently — no
# error is raised. Only nomic-embed models get prefixes; other
# embedding models get the raw text.
DOC_PREFIX = "search_document: "
QUERY_PREFIX = "search_query: "

# The embedding format of the stored vectors. Bump this whenever the
# way document texts are embedded changes, so an index built with the
# old format is detected as stale and rebuilt instead of searched
# with mismatched vectors.
# Format 1: raw text, no prefixes. Format 2: nomic task prefixes.
EMBED_FORMAT_VERSION = 2
INDEX_META_FILENAME = "index_meta.json"


def _uses_nomic_embed(model_id: str) -> bool:
    """True if the embedding model id is a nomic-embed model."""
    return re.search(r"nomic-embed", model_id or "",
                     re.IGNORECASE) is not None


def read_text(path: Path) -> str:
    """Read the text out of a file. Returns "" if it cannot be read."""
    suffix = path.suffix.lower()
    try:
        if suffix == ".pdf":
            from pypdf import PdfReader
            reader = PdfReader(str(path))
            parts = []
            for page in reader.pages:
                try:
                    parts.append(page.extract_text() or "")
                except Exception:
                    continue
            return "\n".join(parts)
        if suffix == ".docx":
            from docx import Document
            doc = Document(str(path))
            return "\n".join(p.text for p in doc.paragraphs)
        # Plain text files (code, notes, markdown, csv, ...).
        try:
            return path.read_text(encoding="utf-8", errors="ignore")
        except Exception:
            return path.read_text(encoding="latin-1", errors="ignore")
    except Exception:
        return ""


def chunk_text(text: str) -> list:
    """Split text into overlapping word chunks."""
    words = text.split()
    if not words:
        return []
    chunks = []
    start = 0
    while start < len(words):
        end = min(start + CHUNK_WORDS, len(words))
        chunks.append(" ".join(words[start:end]))
        if end >= len(words):
            break
        start = end - OVERLAP_WORDS
    return chunks


def _file_id(path: Path) -> str:
    """A short stable id for a file, from its full path."""
    return hashlib.sha1(str(path).encode("utf-8")).hexdigest()[:16]


def _snippet(text: str, query: str, length: int = 160) -> str:
    """A short piece of text around the first query word found in it."""
    words = [w for w in re.split(r"\W+", query.lower()) if len(w) > 2]
    low = text.lower()
    pos = -1
    for w in words:
        pos = low.find(w)
        if pos != -1:
            break
    if pos == -1:
        piece = text[:length]
    else:
        start = max(0, pos - 40)
        piece = text[start:start + length]
    piece = " ".join(piece.split())
    return piece[:length] + ("..." if len(piece) > length else "")


class Indexer:
    """Builds and searches the file index."""

    def __init__(self, data_dir: Path, base_url: str, embed_model: str,
                 progress_cb=None):
        self.data_dir = Path(data_dir)
        self.data_dir.mkdir(parents=True, exist_ok=True)
        # base_url includes the /v1 part, e.g. http://localhost:1234/v1
        self.base_url = base_url.rstrip("/")
        self.embed_model = embed_model
        self._resolved_embed_model = None
        self.progress_cb = progress_cb  # fn(stage, done, total, message)
        self.vector_ok = False
        self.keyword_index = {"version": 1, "files": []}
        self._chroma_client = None
        self._collection = None

    # -- progress ------------------------------------------------------
    def _progress(self, stage, done, total, message):
        if self.progress_cb:
            try:
                self.progress_cb(stage, done, total, message)
            except Exception:
                pass

    # -- LM Studio embeddings ---------------------------------------------
    def _resolve_embed_model(self) -> str:
        """The loaded embedding model id, if LM Studio has it loaded.

        LM Studio sometimes reports ids with a publisher prefix, e.g.
        "nomic-ai/nomic-embed-text-v1.5", so an exact match or a
        "/<name>" suffix both count. Falls back to the configured id.
        """
        if self._resolved_embed_model:
            return self._resolved_embed_model
        try:
            r = requests.get(self.base_url + "/models", timeout=5)
            if r.status_code == 200:
                for m in r.json().get("data", []):
                    mid = m.get("id", "")
                    if mid == self.embed_model or \
                            mid.endswith("/" + self.embed_model):
                        self._resolved_embed_model = mid
                        return mid
        except Exception:
            pass
        return self.embed_model

    def embed_texts(self, texts: list, for_query: bool = False) -> list | None:
        """Turn a list of texts into embeddings via LM Studio.

        POST /v1/embeddings on the LM Studio local server. For a
        nomic-embed model the texts are prefixed before sending
        ("search_document: " for indexed documents, "search_query: "
        for a search query — the model was trained with these task
        prefixes). The prefixes are only sent to the model; the
        stored texts are unchanged. Returns a list of embedding
        vectors, or None if the server or the embedding model is not
        available (then search falls back to keywords).
        """
        if not texts:
            return []
        model = self._resolve_embed_model()
        if _uses_nomic_embed(model):
            prefix = QUERY_PREFIX if for_query else DOC_PREFIX
            send_texts = [prefix + t for t in texts]
        else:
            send_texts = list(texts)
        try:
            r = requests.post(
                self.base_url + "/embeddings",
                json={"model": model,
                      "input": send_texts},
                timeout=120,
            )
            if r.status_code == 200:
                data = r.json().get("data", [])
                vecs = [d.get("embedding") for d in data]
                if len(vecs) == len(texts) and all(v for v in vecs):
                    return vecs
        except Exception:
            pass
        return None

    def embed_query(self, query: str) -> list | None:
        """Embed one search query. Returns one vector, or None."""
        vecs = self.embed_texts([query], for_query=True)
        return vecs[0] if vecs else None

    # -- ChromaDB -------------------------------------------------------
    def _open_collection(self):
        """Open (or create) the ChromaDB collection. Returns None if
        ChromaDB is not installed."""
        if self._collection is not None:
            return self._collection
        try:
            import chromadb
        except ImportError:
            return None
        try:
            if self._chroma_client is None:
                self._chroma_client = chromadb.PersistentClient(
                    path=str(self.data_dir / "chroma")
                )
            self._collection = self._chroma_client.get_or_create_collection(
                name=COLLECTION_NAME,
                metadata={"hnsw:space": "cosine"},
            )
            return self._collection
        except Exception:
            return None

    def _reset_collection(self):
        """Delete the old vector collection so a rebuild starts clean."""
        try:
            import chromadb
            if self._chroma_client is None:
                self._chroma_client = chromadb.PersistentClient(
                    path=str(self.data_dir / "chroma")
                )
            try:
                self._chroma_client.delete_collection(name=COLLECTION_NAME)
            except Exception:
                pass
            self._collection = None
        except Exception:
            self._collection = None

    # -- walking ---------------------------------------------------------
    def _iter_files(self, folders: list) -> list:
        """All readable files under the given folders, skipping junk."""
        found = []
        seen = set()
        for folder in folders:
            folder = Path(folder)
            if not folder.is_dir():
                continue
            for path in folder.rglob("*"):
                try:
                    if path.is_dir():
                        continue
                    if path.name.startswith("."):
                        continue
                    if any(part.lower() in SKIP_DIRS for part in path.parts):
                        continue
                    if path.suffix.lower() not in READABLE_EXTS:
                        continue
                    if path.stat().st_size > MAX_FILE_MB * 1024 * 1024:
                        continue
                    key = str(path.resolve())
                    if key in seen:
                        continue
                    seen.add(key)
                    found.append(path)
                except Exception:
                    continue
        return found

    # -- build ------------------------------------------------------------
    def build(self, folders: list) -> dict:
        """Build (or rebuild) the whole index. Returns a counts dict."""
        counts = {"files": 0, "chunks": 0, "embedded": 0,
                  "keyword_only": 0, "skipped": 0, "errors": 0}
        t0 = time.time()

        self._progress("scan", 0, 1, "Looking through your folders...")
        files = self._iter_files(folders)
        total = max(len(files), 1)

        # Keyword index is built first, so search works even if the
        # vector part fails.
        keyword_files = []
        # Vector part: collect chunks, embed in batches, store in Chroma.
        collection = self._open_collection()
        if collection is not None:
            self._reset_collection()
            collection = self._open_collection()
        self.vector_ok = collection is not None

        batch_texts, batch_ids, batch_metas = [], [], []

        def flush_batch():
            """Embed and store one batch of chunks."""
            nonlocal counts
            if not batch_texts:
                return
            vecs = self.embed_texts(batch_texts) if self.vector_ok else None
            if vecs and collection is not None:
                try:
                    collection.add(
                        ids=list(batch_ids),
                        embeddings=vecs,
                        documents=list(batch_texts),
                        metadatas=list(batch_metas),
                    )
                    counts["embedded"] += len(batch_texts)
                except Exception:
                    self.vector_ok = False
                    counts["keyword_only"] += len(batch_texts)
            else:
                self.vector_ok = False
                counts["keyword_only"] += len(batch_texts)
            batch_texts.clear()
            batch_ids.clear()
            batch_metas.clear()

        for i, path in enumerate(files):
            self._progress("read", i + 1, total, f"Reading {path.name}")
            try:
                text = read_text(path)
            except Exception:
                counts["errors"] += 1
                continue
            if not text.strip():
                counts["skipped"] += 1
                continue
            counts["files"] += 1
            keyword_files.append({
                "path": str(path),
                "name": path.name,
                "folder": str(path.parent),
                "text": text[:KEYWORD_TEXT_LIMIT],
            })
            if self.vector_ok:
                chunks = chunk_text(text)
                counts["chunks"] += len(chunks)
                fid = _file_id(path)
                for j, ch in enumerate(chunks):
                    batch_texts.append(ch)
                    batch_ids.append(f"{fid}-{j}")
                    batch_metas.append({
                        "path": str(path),
                        "name": path.name,
                        "folder": str(path.parent),
                        "chunk": j,
                    })
                    if len(batch_texts) >= 10:
                        flush_batch()
        flush_batch()

        # Save the keyword index.
        self.keyword_index = {"version": 1, "files": keyword_files}
        try:
            with open(self.data_dir / "keyword_index.json", "w",
                      encoding="utf-8") as f:
                json.dump(self.keyword_index, f, ensure_ascii=False)
        except OSError:
            pass

        # The stored vectors now match the current embedding format.
        # If no vectors were stored, nothing may claim to be current.
        if self.vector_ok:
            self._write_index_meta()
        else:
            self._clear_index_meta()

        counts["seconds"] = round(time.time() - t0, 1)
        counts["vector_ok"] = self.vector_ok
        self._progress("done", total, total,
                       f"Done: {counts['files']} files, "
                       f"{counts['chunks']} chunks in {counts['seconds']}s.")
        return counts

    # -- index format marker ------------------------------------------
    def _meta_path(self) -> Path:
        return self.data_dir / INDEX_META_FILENAME

    def _read_index_meta(self) -> dict:
        try:
            with open(self._meta_path(), "r", encoding="utf-8") as f:
                return json.load(f)
        except (json.JSONDecodeError, OSError):
            return {}

    def _write_index_meta(self):
        """Record the embedding format of the vectors just stored."""
        try:
            with open(self._meta_path(), "w", encoding="utf-8") as f:
                json.dump({"embed_format": EMBED_FORMAT_VERSION,
                           "embed_model": self._resolve_embed_model()},
                          f, ensure_ascii=False)
        except OSError:
            pass

    def _clear_index_meta(self):
        try:
            self._meta_path().unlink(missing_ok=True)
        except OSError:
            pass

    def index_is_stale(self) -> bool:
        """True if an index exists but was built with an old embedding
        format (e.g. before the nomic task prefixes were added) — its
        vectors no longer match how new texts are embedded. No index
        at all is not stale: that is a first run, handled by setup."""
        has_index = bool(self.keyword_index.get("files")) or \
            (self.data_dir / "chroma").exists()
        if not has_index:
            return False
        meta = self._read_index_meta()
        return meta.get("embed_format") != EMBED_FORMAT_VERSION

    def load_keyword_index(self):
        """Load the saved keyword index from disk (if the app restarted)."""
        p = self.data_dir / "keyword_index.json"
        if p.is_file():
            try:
                with open(p, "r", encoding="utf-8") as f:
                    self.keyword_index = json.load(f)
            except (json.JSONDecodeError, OSError):
                self.keyword_index = {"version": 1, "files": []}
        # Vector availability: ChromaDB installed and collection exists.
        try:
            import chromadb  # noqa: F401
            self.vector_ok = (self.data_dir / "chroma").exists()
        except ImportError:
            self.vector_ok = False

    # -- search ------------------------------------------------------------
    def search(self, query: str, top_n: int = 8) -> list:
        """Search by meaning first, by keyword if vectors are not ready.

        Returns a list of dicts: {path, name, folder, snippet, score}.
        """
        query = (query or "").strip()
        if not query:
            return []
        if self.vector_ok:
            results = self._vector_search(query, top_n)
            if results:
                return results
        return self.keyword_search(query, top_n)

    def _vector_search(self, query: str, top_n: int) -> list:
        collection = self._open_collection()
        if collection is None:
            return []
        vec = self.embed_query(query)
        if not vec:
            return []
        try:
            res = collection.query(
                query_embeddings=[vec],
                n_results=top_n * 2,
                include=["documents", "metadatas", "distances"],
            )
        except Exception:
            return []
        docs = (res.get("documents") or [[]])[0]
        metas = (res.get("metadatas") or [[]])[0]
        dists = (res.get("distances") or [[]])[0]
        seen = {}
        for doc, meta, dist in zip(docs, metas, dists):
            path = meta.get("path", "")
            if path in seen:
                continue
            seen[path] = {
                "path": path,
                "name": meta.get("name", Path(path).name),
                "folder": meta.get("folder", ""),
                "snippet": " ".join((doc or "").split())[:160],
                "score": round(1 - float(dist), 3),
            }
            if len(seen) >= top_n:
                break
        return list(seen.values())

    def keyword_search(self, query: str, top_n: int = 8) -> list:
        """Plain word search over file names and file text.

        A word in the file name scores 10, a word in the text scores 1
        per hit (capped). Best matches first.
        """
        words = [w for w in re.split(r"\W+", query.lower()) if len(w) > 2]
        if not words:
            words = [query.lower()]
        scored = []
        for entry in self.keyword_index.get("files", []):
            name = entry.get("name", "").lower()
            text = entry.get("text", "")
            low = text.lower()
            score = 0
            for w in words:
                if w in name:
                    score += 10
                score += min(low.count(w), 20)
            if score > 0:
                scored.append((score, entry))
        scored.sort(key=lambda x: x[0], reverse=True)
        out = []
        for score, entry in scored[:top_n]:
            out.append({
                "path": entry.get("path", ""),
                "name": entry.get("name", ""),
                "folder": entry.get("folder", ""),
                "snippet": _snippet(entry.get("text", ""), query),
                "score": score,
            })
        return out

    def get_file_text(self, path: str, max_chars: int = 8000) -> str:
        """Read a file's text (for summaries)."""
        return read_text(Path(path))[:max_chars]

    def status(self) -> dict:
        """Small status dict for the GUI status bar."""
        n = len(self.keyword_index.get("files", []))
        return {"vector_ok": self.vector_ok, "files_indexed": n}
