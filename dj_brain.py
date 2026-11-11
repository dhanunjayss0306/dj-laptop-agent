"""DJ brain — talks to the local models in LM Studio and decides what to do.

DJ uses LM Studio's built-in local server (OpenAI-compatible API) at
http://localhost:1234/v1:
  * GET  /v1/models            — which models are loaded right now
  * POST /v1/chat/completions — ask the loaded chat model
  * POST /v1/embeddings       — embeddings (used by dj_indexer)

One loaded chat model does both jobs: it understands what the user
said and decides the action. On startup DJ asks LM Studio which model
is loaded and uses that one, so it works with whatever model the user
has loaded (Llama, Qwen, Gemma, ...).

The brain answers with one small JSON object:
  {"action": "search" | "open" | "summarize" | "organize" | "list" | "open_app",
   "query": "..."}

DJ cannot start LM Studio itself. If the LM Studio server is not
running, or no model is loaded, DJ says so plainly and falls back to
simple keyword rules, so finding files still works without any AI.
"""

import json
import re

import requests

SYSTEM_PROMPT = """You are DJ, a private laptop assistant. The user talks to you
in plain English. Reply with ONLY one JSON object, no other text.

{"action": "search", "query": "..."}       - find files by name or topic
{"action": "open", "query": "..."}         - open a file the user names, or open files about a topic
{"action": "summarize", "query": "..."}    - summarize a file the user names
{"action": "organize", "query": "today"}   - organize today's Downloads
{"action": "list", "query": "..."}         - list files, e.g. recent files
{"action": "open_app", "query": "notepad"} - open an installed app by name

Rules:
- "find my Virun pitch" -> {"action": "search", "query": "Virun pitch"}
- "open something about travel and tourism" -> {"action": "open", "query": "travel and tourism"}
- "summarize this file" or "summarize my Virun pitch" -> {"action": "summarize", "query": "Virun pitch"}
- "organize today's Downloads" -> {"action": "organize", "query": "today"}
- "open notepad" or "open chrome" -> {"action": "open_app", "query": "notepad"}
- If the user just names a topic, use "search" with that topic as the query.
- The query is the file name, topic, or app name — never the whole sentence.
Reply with ONLY the JSON object.
"""


class Brain:
    """Talks to LM Studio's local server at http://localhost:1234/v1."""

    def __init__(self, base_url: str, chat_model: str = "",
                 embed_model: str = "nomic-embed-text-v1.5"):
        # base_url includes the /v1 part, e.g. http://localhost:1234/v1
        self.base_url = base_url.rstrip("/")
        # chat_model may be "" — that means "use whatever model is
        # loaded in LM Studio right now" (discovered on startup).
        self.configured_chat_model = (chat_model or "").strip()
        self.chat_model = self.configured_chat_model
        self.embed_model = embed_model
        self.loaded_models: list = []

    # -- connection -------------------------------------------------------
    def refresh_models(self, timeout: int = 5) -> bool:
        """Ask LM Studio which models are loaded. True if it answers.

        Also picks the chat model to use (see _resolve_chat_model).
        """
        try:
            r = requests.get(self.base_url + "/models", timeout=timeout)
            if r.status_code == 200:
                self.loaded_models = [
                    m.get("id", "") for m in r.json().get("data", [])
                    if m.get("id")
                ]
                self._resolve_chat_model()
                return True
        except Exception:
            pass
        self.loaded_models = []
        return False

    def ping(self, timeout: int = 3) -> bool:
        """True if the LM Studio server answers."""
        return self.refresh_models(timeout=timeout)

    def list_models(self) -> set:
        """Ids of the models LM Studio has loaded right now."""
        if not self.loaded_models:
            self.refresh_models()
        return set(self.loaded_models)

    @staticmethod
    def _match_model(want: str, loaded: list) -> str | None:
        """Find `want` among the loaded model ids.

        LM Studio sometimes reports ids with a publisher prefix, e.g.
        "nomic-ai/nomic-embed-text-v1.5", so an exact match or a
        "/want" suffix both count.
        """
        if not want:
            return None
        for mid in loaded:
            if mid == want or mid.endswith("/" + want):
                return mid
        return None

    def _resolve_chat_model(self):
        """Pick the chat model: the configured one if it is loaded,
        otherwise the first loaded model that is not an embedding
        model, otherwise the first loaded model."""
        matched = self._match_model(self.configured_chat_model,
                                    self.loaded_models)
        if matched:
            self.chat_model = matched
            return
        for mid in self.loaded_models:
            if mid == self.embed_model or "embed" in mid.lower():
                continue
            self.chat_model = mid
            return
        self.chat_model = (self.loaded_models[0]
                           if self.loaded_models else "")

    def embedding_ready(self) -> bool:
        """True if the embedding model is loaded in LM Studio."""
        if not self.loaded_models:
            self.refresh_models()
        return self._match_model(self.embed_model,
                                 self.loaded_models) is not None

    # -- chat ---------------------------------------------------------------
    def _chat(self, model: str, messages: list, temperature: float = 0.1,
              timeout: int = 120) -> str:
        """One chat call to LM Studio. Returns the reply text (may be '')."""
        if not model:
            self.refresh_models()
            model = self.chat_model
        if not model:
            return ""
        try:
            r = requests.post(
                self.base_url + "/chat/completions",
                json={
                    "model": model,
                    "messages": messages,
                    "temperature": temperature,
                },
                timeout=timeout,
            )
            if r.status_code == 200:
                choices = r.json().get("choices", [])
                if choices:
                    return choices[0].get("message", {}).get("content", "")
        except Exception:
            pass
        return ""

    def decide(self, text: str) -> dict:
        """Turn the user's words into an action dict.

        Asks the local model first; if that fails, uses simple rules.
        Always returns a dict with "action" and "query".
        """
        reply = self._chat(
            self.chat_model,
            [
                {"role": "system", "content": SYSTEM_PROMPT},
                {"role": "user", "content": text},
            ],
        )
        action = self._parse_action_json(reply)
        if action:
            return action
        return self._rule_decide(text)

    @staticmethod
    def _parse_action_json(reply: str) -> dict | None:
        """Pull a {"action": ..., "query": ...} object out of model text."""
        if not reply:
            return None
        match = re.search(r"\{[^{}]*\}", reply, re.DOTALL)
        if not match:
            return None
        try:
            data = json.loads(match.group(0))
        except json.JSONDecodeError:
            return None
        action = str(data.get("action", "")).strip().lower()
        query = str(data.get("query", "")).strip()
        if action in ("search", "open", "summarize", "organize", "list",
                      "open_app") and query:
            return {"action": action, "query": query}
        return None

    # -- offline fallback: simple keyword rules ---------------------------
    @staticmethod
    def _rule_decide(text: str) -> dict:
        """Decide without any model, from the words themselves."""
        low = text.lower().strip()

        if "organiz" in low:
            return {"action": "organize", "query": "today"}

        if "summar" in low:
            query = _after_words(low, ["summarize", "summarise", "summary of",
                                       "summarize this file", "summarise this file"])
            return {"action": "summarize", "query": query or text}

        if low.startswith("open "):
            rest = low[5:].strip()
            rest = re.sub(r"^(something|anything|all the things|the files?|a file)\s+(about|on|related to)\s+",
                          "", rest)
            rest = re.sub(r"^(something|anything)\s+about\s+", "", rest)
            # A known app name -> open the app, anything else -> open files.
            if rest in ("notepad", "chrome", "calculator", "paint", "word",
                        "excel", "powerpoint", "edge", "vs code", "code",
                        "spotify", "whatsapp", "explorer", "settings"):
                return {"action": "open_app", "query": rest}
            return {"action": "open", "query": rest or text}

        for word in ("find ", "search ", "search for ", "look for ",
                     "where is ", "where are ", "show me "):
            if low.startswith(word):
                return {"action": "search", "query": text[len(word):].strip()}

        if low.startswith(("list ", "show ")):
            return {"action": "list", "query": text}

        return {"action": "search", "query": text}

    def summarize(self, text: str, filename: str) -> str:
        """Short summary of a file's text, in simple English."""
        if not text.strip():
            return "That file looks empty, so there is nothing to summarize."
        prompt = (
            f"Summarize this file in 5 short bullet points, in simple "
            f"English. File name: {filename}\n\n{text[:6000]}"
        )
        reply = self._chat(
            self.chat_model,
            [{"role": "user", "content": prompt}],
            temperature=0.2,
        )
        if reply.strip():
            return reply.strip()
        # No model? Give the first lines as a plain fallback.
        lines = [ln.strip() for ln in text.splitlines() if ln.strip()]
        return ("(LM Studio is not answering, so here are the first lines "
                "of the file instead:)\n" + "\n".join(lines[:8]))


def _after_words(text: str, words: list) -> str:
    """Text after the first matching word, or '' if none match."""
    for w in words:
        if w in text:
            return text.split(w, 1)[1].strip(" :")
    return ""
