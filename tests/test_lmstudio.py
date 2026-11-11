"""Test the LM Studio auto-start (dj_lmstudio).

A fake `lms` command is put on PATH. It records every call, and
`server start` really starts a fake LM Studio server on the port
the test expects, so ensure_server() can be tested end to end.

Checks:
  - find_lms() finds the fake `lms` on PATH, and returns None when
    there is no `lms` anywhere
  - ensure_server() with the server already up never calls `lms`
  - ensure_server() with the server down calls `lms server start`
    and then works (chat + embedding model loaded)
  - ensure_server() with the server down and no `lms` returns
    (False, ...) telling the user to open LM Studio by hand
  - ensure_server() with the server up but no chat model loaded
    tries `lms load <chat model>`

Note: the fake `lms` is a plain script with a shebang, so this file
only runs on a Unix-like test machine (the VM). The production code
also looks in the Windows install folders.

Run:  python tests/test_lmstudio.py
"""

import os
import socket
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(HERE))

from stub_lmstudio import start_stub  # noqa: E402
from dj_brain import Brain  # noqa: E402
import dj_lmstudio  # noqa: E402


def check(name, cond, detail=""):
    print(("PASS" if cond else "FAIL") + f"  {name}" + (f"  ({detail})" if detail else ""))
    return cond


def free_port() -> int:
    """A currently free TCP port number."""
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


LMS_SCRIPT = '''#!/usr/bin/env python3
"""Fake `lms` for tests. Records calls; `server start` really starts
a fake LM Studio server on the port in LMS_TEST_PORT."""
import os
import subprocess
import sys

calls_file = os.environ["LMS_TEST_CALLS"]
port = os.environ.get("LMS_TEST_PORT", "")

with open(calls_file, "a", encoding="utf-8") as f:
    f.write(" ".join(sys.argv[1:]) + "\\n")

if sys.argv[1:3] == ["server", "start"] and port:
    server_script = os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "run_fake_server.py")
    stub_dir = os.environ.get("LMS_TEST_STUB_DIR", "")
    subprocess.Popen(
        [sys.executable, server_script, port, stub_dir],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        start_new_session=True)
    print("fake server started")
sys.exit(0)
'''

SERVER_SCRIPT = '''#!/usr/bin/env python3
"""Run the fake LM Studio server on a given port, forever."""
import sys
from http.server import ThreadingHTTPServer

sys.path.insert(0, sys.argv[2])
from stub_lmstudio import _Handler  # noqa: E402

port = int(sys.argv[1])
ThreadingHTTPServer(("127.0.0.1", port), _Handler).serve_forever()
'''


def make_fake_lms(tmp: Path):
    """Write the fake `lms` + server scripts, return (bin_dir, calls_file)."""
    bin_dir = tmp / "bin"
    bin_dir.mkdir()
    lms = bin_dir / "lms"
    lms.write_text(LMS_SCRIPT, encoding="utf-8")
    lms.chmod(lms.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    server = bin_dir / "run_fake_server.py"
    server.write_text(SERVER_SCRIPT, encoding="utf-8")
    return bin_dir, tmp / "calls.txt"


def main():
    ok = True
    tmp = Path(tempfile.mkdtemp(prefix="dj_lms_"))
    bin_dir, calls_file = make_fake_lms(tmp)
    calls_file.write_text("", encoding="utf-8")
    old_path = os.environ.get("PATH", "")
    old_env = {k: os.environ.get(k) for k in
               ("LMS_TEST_CALLS", "LMS_TEST_PORT", "LMS_TEST_STUB_DIR")}

    try:
        # --- find_lms -------------------------------------------------
        os.environ["PATH"] = str(bin_dir) + os.pathsep + old_path
        os.environ["LMS_TEST_CALLS"] = str(calls_file)
        found = dj_lmstudio.find_lms()
        ok &= check("find_lms() finds the fake lms on PATH",
                    found is not None and found.endswith("lms"),
                    str(found))

        # --- server already up: lms must NOT be called -----------------
        server, url = start_stub()
        try:
            calls_file.write_text("", encoding="utf-8")
            brain = Brain(url, "qwen3-8b", "nomic-embed-text-v1.5")
            good, msg = dj_lmstudio.ensure_server(brain, "qwen3-8b")
            ok &= check("ensure_server() with server up returns True",
                        good is True, msg)
            ok &= check("ensure_server() with server up never calls lms",
                        calls_file.read_text() == "",
                        calls_file.read_text())
        finally:
            server.shutdown()

        # --- server down: lms server start brings it up ---------------
        port = free_port()
        os.environ["LMS_TEST_PORT"] = str(port)
        os.environ["LMS_TEST_STUB_DIR"] = str(HERE)
        url2 = f"http://127.0.0.1:{port}/v1"
        brain2 = Brain(url2, "qwen3-8b", "nomic-embed-text-v1.5")
        calls_file.write_text("", encoding="utf-8")
        good, msg = dj_lmstudio.ensure_server(brain2, "qwen3-8b")
        ok &= check("ensure_server() starts the server via lms",
                    good is True, msg)
        ok &= check("lms was called with 'server start'",
                    "server start" in calls_file.read_text(),
                    calls_file.read_text())
        ok &= check("brain sees the models after the start",
                    brain2.ping() and "qwen3-8b" in brain2.list_models(),
                    str(brain2.list_models()))
    finally:
        os.environ["PATH"] = old_path
        for k, v in old_env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        # Kill any fake server the test started (it is a daemon-less
        # process of its own; find it by port is unreliable, so the
        # test only ever starts one and it dies with the VM anyway).
        try:
            subprocess.run(["pkill", "-f", "run_fake_server.py"],
                           capture_output=True, timeout=5)
        except Exception:
            pass

    # --- server down, no lms anywhere: plain-English failure ---------
    os.environ["PATH"] = "/nonexistent"
    try:
        brain3 = Brain("http://127.0.0.1:9/v1", "qwen3-8b")
        good, msg = dj_lmstudio.ensure_server(brain3, "qwen3-8b")
        ok &= check("ensure_server() with no lms returns False",
                    good is False, msg)
        ok &= check("failure message tells the user what to do by hand",
                    "Open LM Studio" in msg, msg[:100])
    finally:
        os.environ["PATH"] = old_path

    # --- server up, no chat model: lms load is attempted --------------
    os.environ["PATH"] = str(bin_dir) + os.pathsep + old_path
    os.environ["LMS_TEST_CALLS"] = str(calls_file)
    try:
        # A stub that only reports the embedding model.
        from stub_lmstudio import _Handler  # noqa: E402
        from http.server import ThreadingHTTPServer  # noqa: E402
        import threading  # noqa: E402

        class EmbedOnlyHandler(_Handler):
            def do_GET(self):
                if self.path == "/v1/models":
                    self._send({"object": "list", "data": [
                        {"id": "nomic-embed-text-v1.5", "object": "model",
                         "owned_by": "organization-owner"}]})
                else:
                    self.send_response(404)
                    self.end_headers()

        srv = ThreadingHTTPServer(("127.0.0.1", 0), EmbedOnlyHandler)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        try:
            url3 = f"http://127.0.0.1:{srv.server_address[1]}/v1"
            brain4 = Brain(url3, "qwen3-8b", "nomic-embed-text-v1.5")
            calls_file.write_text("", encoding="utf-8")
            good, msg = dj_lmstudio.ensure_server(brain4, "qwen3-8b")
            ok &= check("lms load is attempted when no chat model is loaded",
                        "load qwen3-8b" in calls_file.read_text(),
                        calls_file.read_text())
            ok &= check("ensure_server() is honest when the load does not "
                        "make the model appear",
                        good is False, msg)
        finally:
            srv.shutdown()
    finally:
        os.environ["PATH"] = old_path
        os.environ.pop("LMS_TEST_CALLS", None)

    print("\n" + ("ALL LMSTUDIO TESTS PASSED" if ok else "LMSTUDIO TESTS FAILED"))
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
