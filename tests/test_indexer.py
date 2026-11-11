"""Test the indexer: build the index over the sample files and search.

Two modes are tested:
  1. Keyword mode (no LM Studio) — the fallback that always works.
  2. Vector mode (fake LM Studio stub) — embeddings through the stub,
     stored in a real ChromaDB collection, searched by meaning.

Checks:
  - "travel and tourism" finds the Virun pitch and the Kerala notes.
  - "Virun pitch" finds the Virun pitch file first (file-name match).
  - "sanitation" finds the SAPSS PDF (tests PDF text extraction).
  - "operating system lab" finds the docx (tests docx extraction).
  - "cricket score" finds the python file.
  - A nonsense query returns nothing.
  - nomic-embed prefixes: document chunks are sent with
    "search_document: ", the query with "search_query: ", nothing is
    stored with a prefix, and a non-nomic model gets no prefix.
  - Index format marker: a build writes it, an old or missing marker
    with an index on disk is stale, no index at all is not stale.

Run:  python tests/test_indexer.py
"""

import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(HERE))

from make_sample_files import main as make_samples, SAMPLE_DIR  # noqa: E402
from dj_indexer import Indexer  # noqa: E402


def check(name, cond, detail=""):
    print(("PASS" if cond else "FAIL") + f"  {name}" + (f"  ({detail})" if detail else ""))
    return cond


def main():
    make_samples()
    ok = True
    tmp = Path(tempfile.mkdtemp(prefix="dj_test_"))

    # ---- 1. Keyword mode: LM Studio URL points at nothing ----------------
    idx = Indexer(tmp / "data_kw", "http://127.0.0.1:9/v1",
                  "nomic-embed-text-v1.5")
    counts = idx.build([SAMPLE_DIR])
    ok &= check("keyword build reads 5 files", counts["files"] == 5,
                f"got {counts['files']}")
    ok &= check("keyword mode: vector_ok is False", counts["vector_ok"] is False)

    res = idx.search("travel and tourism")
    names = [r["name"] for r in res]
    ok &= check("'travel and tourism' finds Virun pitch (keyword)",
                any("Virun pitch" in n for n in names), str(names))
    ok &= check("'travel and tourism' finds Kerala notes (keyword)",
                any("Kerala" in n for n in names), str(names))

    res = idx.search("Virun pitch")
    ok &= check("'Virun pitch' is the top hit",
                res and "Virun pitch" in res[0]["name"],
                res[0]["name"] if res else "no results")

    res = idx.search("sanitation")
    ok &= check("'sanitation' finds the SAPSS PDF",
                res and "SAPSS" in res[0]["name"],
                res[0]["name"] if res else "no results")

    res = idx.search("operating system lab")
    ok &= check("'operating system lab' finds the docx",
                res and res[0]["name"].endswith(".docx"),
                res[0]["name"] if res else "no results")

    res = idx.search("cricket score")
    ok &= check("'cricket score' finds the python file",
                res and res[0]["name"].endswith(".py"),
                res[0]["name"] if res else "no results")

    res = idx.search("zzzzqqqxxy")
    ok &= check("nonsense query returns nothing", res == [], str(res))

    # Keyword index survives a restart (load from disk).
    idx2 = Indexer(tmp / "data_kw", "http://127.0.0.1:9/v1",
                   "nomic-embed-text-v1.5")
    idx2.load_keyword_index()
    res = idx2.search("Virun pitch")
    ok &= check("keyword index loads from disk after restart",
                res and "Virun pitch" in res[0]["name"])

    # ---- 2. Vector mode: fake LM Studio stub + real ChromaDB ------------
    from stub_lmstudio import (RECEIVED_EMBED_INPUTS, reset_received,
                               start_stub)
    from dj_indexer import DOC_PREFIX, QUERY_PREFIX, EMBED_FORMAT_VERSION
    import json as _json
    server, url = start_stub()
    try:
        reset_received()
        vidx = Indexer(tmp / "data_vec", url, "nomic-embed-text-v1.5")
        counts = vidx.build([SAMPLE_DIR])
        ok &= check("vector build reads 5 files", counts["files"] == 5,
                    f"got {counts['files']}")
        ok &= check("vector mode: vector_ok is True",
                    counts["vector_ok"] is True)
        ok &= check("vector build embedded chunks",
                    counts["embedded"] > 0, f"embedded={counts['embedded']}")

        # Prefixes: document chunks are sent with "search_document: ".
        ok &= check("document chunks sent with search_document: prefix",
                    RECEIVED_EMBED_INPUTS and all(
                        t.startswith(DOC_PREFIX)
                        for t in RECEIVED_EMBED_INPUTS),
                    f"got {len(RECEIVED_EMBED_INPUTS)} inputs")
        # ...but the prefix is only sent to the model: the stored
        # documents in ChromaDB keep the raw chunk text.
        stored = vidx._open_collection().get()
        docs = stored.get("documents", [])
        ok &= check("stored documents have no prefix",
                    docs and all(not d.startswith(DOC_PREFIX)
                                 for d in docs),
                    f"got {len(docs)} docs")

        res = vidx.search("travel and tourism")
        names = [r["name"] for r in res]
        ok &= check("'travel and tourism' finds Virun pitch (vector)",
                    any("Virun pitch" in n for n in names), str(names))
        ok &= check("'travel and tourism' top hit is travel-related (vector)",
                    res and ("Virun" in res[0]["name"] or "Kerala" in res[0]["name"]),
                    res[0]["name"] if res else "no results")

        # The search query itself is sent with "search_query: ".
        ok &= check("search query sent with search_query: prefix",
                    RECEIVED_EMBED_INPUTS and
                    RECEIVED_EMBED_INPUTS[-1].startswith(QUERY_PREFIX),
                    RECEIVED_EMBED_INPUTS[-1][:40]
                    if RECEIVED_EMBED_INPUTS else "nothing recorded")

        res = vidx.search("sanitation public toilets")
        ok &= check("'sanitation public toilets' finds SAPSS PDF (vector)",
                    res and "SAPSS" in res[0]["name"],
                    res[0]["name"] if res else "no results")

        # A non-nomic embedding model gets no prefix at all.
        reset_received()
        other = Indexer(tmp / "data_other", url, "text-embedding-3-small")
        counts = other.build([SAMPLE_DIR])
        ok &= check("non-nomic build embedded chunks",
                    counts["embedded"] > 0, f"embedded={counts['embedded']}")
        ok &= check("non-nomic model gets no prefix",
                    RECEIVED_EMBED_INPUTS and all(
                        not t.startswith((DOC_PREFIX, QUERY_PREFIX))
                        for t in RECEIVED_EMBED_INPUTS),
                    f"got {len(RECEIVED_EMBED_INPUTS)} inputs")
    finally:
        server.shutdown()

    # ---- 3. Index format marker / stale detection ----------------------
    meta_path = tmp / "data_vec" / "index_meta.json"
    ok &= check("build writes the index format marker",
                meta_path.is_file())
    meta = _json.loads(meta_path.read_text(encoding="utf-8"))
    ok &= check("marker has the current format version",
                meta.get("embed_format") == EMBED_FORMAT_VERSION,
                str(meta))
    ok &= check("current index is not stale",
                vidx.index_is_stale() is False)
    # An old-format marker means the index is stale.
    meta_path.write_text(_json.dumps({"embed_format": 1}),
                         encoding="utf-8")
    ok &= check("old-format marker is stale",
                vidx.index_is_stale() is True)
    # A missing marker with an index on disk is also stale.
    meta_path.unlink()
    ok &= check("missing marker with an index is stale",
                vidx.index_is_stale() is True)
    # No index at all is not stale (first run, not an old index).
    fresh = Indexer(tmp / "data_fresh", "http://127.0.0.1:9/v1",
                    "nomic-embed-text-v1.5")
    fresh.load_keyword_index()
    ok &= check("no index at all is not stale",
                fresh.index_is_stale() is False)

    print("\n" + ("ALL INDEXER TESTS PASSED" if ok else "INDEXER TESTS FAILED"))
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
