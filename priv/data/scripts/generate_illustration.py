#!/usr/bin/env python3
"""Generate an illustration via the Gemini image API.

Usage: python3 generate_illustration.py "prompt text" /path/to/out.png

Run it exactly like that — a direct interpreter invocation. (OpenClaw's exec
preflight refuses compound shell commands like `source .env && python3 ...`.)
Reads IMAGE_GEN_API_KEY (required) and IMAGE_GEN_MODEL (optional) from the
environment, falling back to ~/.openclaw/.env so no shell sourcing is needed.
"""

import base64
import json
import os
import sys
import urllib.request

def load_openclaw_env():
    """Fill in missing env vars from ~/.openclaw/.env (KEY=VALUE lines)."""
    path = os.path.expanduser("~/.openclaw/.env")
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, value = line.partition("=")
                os.environ.setdefault(key.strip(), value.strip())
    except OSError:
        pass

def main():
    load_openclaw_env()
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        sys.exit(2)

    prompt, out_path = sys.argv[1], sys.argv[2]
    key = os.environ.get("IMAGE_GEN_API_KEY")
    if not key:
        print("IMAGE_GEN_API_KEY not set", file=sys.stderr)
        sys.exit(1)
    model = os.environ.get("IMAGE_GEN_MODEL", "gemini-2.5-flash-image")

    url = f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"
    body = {
        "contents": [{"parts": [{"text": prompt}]}],
        "generationConfig": {"responseModalities": ["IMAGE"]},
    }
    req = urllib.request.Request(
        url,
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json", "x-goog-api-key": key},
    )
    with urllib.request.urlopen(req, timeout=120) as resp:
        data = json.load(resp)

    for cand in data.get("candidates", []):
        for part in cand.get("content", {}).get("parts", []):
            inline = part.get("inlineData") or part.get("inline_data")
            if inline and inline.get("data"):
                os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
                with open(out_path, "wb") as f:
                    f.write(base64.b64decode(inline["data"]))
                print(out_path)
                return

    print("No image in response: " + json.dumps(data)[:500], file=sys.stderr)
    sys.exit(1)

if __name__ == "__main__":
    main()
