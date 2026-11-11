#!/usr/bin/env python3
"""DJ — a private, free, local laptop assistant.

Run it with:
    python dj.py

DJ talks to LM Studio's local server on http://localhost:1234/v1 (your
own loaded model — Llama, Qwen, Gemma, whatever you loaded in LM
Studio) and keeps a private search index of the folders you pick.
Nothing leaves the laptop, no paid API, no account, no cloud.

Before running DJ: DJ tries to start LM Studio itself with the `lms`
tool. If it cannot, it tells you plainly: open LM Studio, load your
model, click Start Server (Developer tab), and leave LM Studio open
while you use DJ.

First run: DJ asks which folders it may look in, then builds the index.
"""

import os
import sys

# Make sure the modules next to this file can be imported, no matter
# which folder the command prompt is in.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from dj_gui import main  # noqa: E402

if __name__ == "__main__":
    main()
