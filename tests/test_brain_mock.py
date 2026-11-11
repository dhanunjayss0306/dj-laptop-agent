"""Test the brain against the fake LM Studio stub, and the offline fallback.

Checks:
  - ping() is True against the stub; list_models() sees the stub models
  - auto-discovery: Brain with no chat model configured picks the loaded
    chat model (qwen3-8b) from GET /v1/models
  - embedding_ready() is True when nomic-embed-text-v1.5 is loaded
  - decide("find my Virun pitch") -> {"action": "search", "query": "Virun pitch"}
  - decide("open something about travel and tourism") -> open / travel and tourism
  - decide("organize today's Downloads") -> organize / today
  - decide("open notepad") -> open_app / notepad
  - decide() with the server down -> keyword-rule fallback still returns an action
  - summarize() with the stub returns the canned summary
  - summarize() with the server down returns the first-lines fallback
  - ping() is False when nothing listens
  - _match_model matches a publisher-prefixed id ("nomic-ai/nomic-embed-text-v1.5")
  - _parse_action_json returns None for garbage text

Run:  python tests/test_brain_mock.py
"""

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(HERE))

from stub_lmstudio import start_stub  # noqa: E402
from dj_brain import Brain  # noqa: E402


def check(name, cond, detail=""):
    print(("PASS" if cond else "FAIL") + f"  {name}" + (f"  ({detail})" if detail else ""))
    return cond


def main():
    ok = True
    server, url = start_stub()
    try:
        # No chat model configured: DJ must discover the loaded one.
        brain = Brain(url)
        ok &= check("ping() is True against the stub", brain.ping())
        ok &= check("list_models() sees the stub models",
                    {"qwen3-8b", "nomic-embed-text-v1.5"}
                    <= brain.list_models(), str(brain.list_models()))
        ok &= check("auto-discovery picks the loaded chat model",
                    brain.chat_model == "qwen3-8b", brain.chat_model)
        ok &= check("embedding_ready() is True (model loaded)",
                    brain.embedding_ready())

        # Configured chat model that is loaded: use it as-is.
        brain2 = Brain(url, "qwen3-8b", "nomic-embed-text-v1.5")
        brain2.refresh_models()
        ok &= check("configured chat model is used when loaded",
                    brain2.chat_model == "qwen3-8b", brain2.chat_model)

        a = brain.decide("find my Virun pitch")
        ok &= check("decide find -> search / Virun pitch",
                    a == {"action": "search", "query": "Virun pitch"}, str(a))

        a = brain.decide("open something about travel and tourism")
        ok &= check("decide open about -> open / travel and tourism",
                    a == {"action": "open", "query": "travel and tourism"}, str(a))

        a = brain.decide("organize today's Downloads")
        ok &= check("decide organize -> organize / today",
                    a == {"action": "organize", "query": "today"}, str(a))

        a = brain.decide("organize yesterday's Downloads")
        ok &= check("decide organize yesterday -> organize / yesterday",
                    a == {"action": "organize", "query": "yesterday"},
                    str(a))

        a = brain.decide("organize the last 3 days")
        ok &= check("decide organize last 3 days -> organize / last 3 days",
                    a == {"action": "organize", "query": "last 3 days"},
                    str(a))

        a = brain.decide("organize my files in Downloads")
        ok &= check("decide organize with no range -> organize / '' (ask)",
                    a == {"action": "organize", "query": ""}, str(a))

        a = brain.decide("find duplicates")
        ok &= check("decide find duplicates -> duplicates",
                    a == {"action": "duplicates", "query": ""}, str(a))

        a = brain.decide("delete the extra copies")
        ok &= check("decide delete extra copies -> duplicates / delete",
                    a == {"action": "duplicates", "query": "delete"}, str(a))

        a = brain.decide("open notepad")
        ok &= check("decide open notepad -> open_app / notepad",
                    a == {"action": "open_app", "query": "notepad"}, str(a))

        s = brain.summarize("Virun is a travel app. " * 20, "Virun pitch.md")
        ok &= check("summarize() returns the stub summary",
                    "travel app" in s.lower(), s[:80])
    finally:
        server.shutdown()

    # ---- Server down: everything must still degrade gracefully -----------
    dead = Brain("http://127.0.0.1:9/v1")
    ok &= check("ping() is False when the server is down", dead.ping() is False)
    ok &= check("embedding_ready() is False when the server is down",
                dead.embedding_ready() is False)

    a = dead.decide("find my Virun pitch")
    ok &= check("offline fallback: find -> search",
                a.get("action") == "search" and "virun" in a.get("query", "").lower(),
                str(a))
    a = dead.decide("organize today's Downloads")
    ok &= check("offline fallback: organize -> organize",
                a == {"action": "organize", "query": "today"}, str(a))
    a = dead.decide("organize my files in Downloads")
    ok &= check("offline fallback: organize with no range -> ask",
                a == {"action": "organize", "query": ""}, str(a))
    a = dead.decide("organize yesterday's Downloads")
    ok &= check("offline fallback: organize yesterday",
                a == {"action": "organize", "query": "yesterday"}, str(a))
    a = dead.decide("organize the last 5 days")
    ok &= check("offline fallback: organize last 5 days",
                a == {"action": "organize", "query": "last 5 days"}, str(a))
    a = dead.decide("find duplicates")
    ok &= check("offline fallback: find duplicates -> duplicates",
                a == {"action": "duplicates", "query": ""}, str(a))
    a = dead.decide("delete the extra copies")
    ok &= check("offline fallback: delete extra copies -> duplicates",
                a == {"action": "duplicates", "query": "delete"}, str(a))
    a = dead.decide("open something about travel and tourism")
    ok &= check("offline fallback: open about -> open",
                a.get("action") == "open" and "travel" in a.get("query", ""),
                str(a))

    s = dead.summarize("First line here.\nSecond line here.\n", "notes.txt")
    ok &= check("offline summarize falls back to first lines",
                "First line here" in s, s[:80])

    ok &= check("_match_model matches a publisher-prefixed id",
                Brain._match_model("nomic-embed-text-v1.5",
                                   ["nomic-ai/nomic-embed-text-v1.5"])
                == "nomic-ai/nomic-embed-text-v1.5")
    ok &= check("_match_model returns None when not loaded",
                Brain._match_model("nomic-embed-text-v1.5", ["qwen3-8b"])
                is None)

    ok &= check("_parse_action_json returns None for garbage",
                Brain._parse_action_json("hello there, no json") is None)
    parsed = Brain._parse_action_json(
        'Sure! {"action": "search", "query": "test"} done.')
    ok &= check("_parse_action_json pulls JSON out of chatty text",
                parsed == {"action": "search", "query": "test"}, str(parsed))
    ok &= check("_parse_action_json accepts duplicates with no query",
                Brain._parse_action_json(
                    '{"action": "duplicates", "query": ""}')
                == {"action": "duplicates", "query": ""})
    ok &= check("_parse_action_json accepts organize with empty query",
                Brain._parse_action_json(
                    '{"action": "organize", "query": ""}')
                == {"action": "organize", "query": ""})

    print("\n" + ("ALL BRAIN TESTS PASSED" if ok else "BRAIN TESTS FAILED"))
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
