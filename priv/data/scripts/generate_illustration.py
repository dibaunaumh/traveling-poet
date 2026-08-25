#!/usr/bin/env python3
"""Generate an illustration via the Gemini image API.

Usage: python3 generate_illustration.py "prompt text" /path/to/out.png

Reads IMAGE_GEN_API_KEY (required) and IMAGE_GEN_MODEL (optional) from the
environment (~/.openclaw/.env is loaded into the gateway's env at startup;
when running from a plain shell, `export $(grep -v '^#' ~/.openclaw/.env | xargs)` first).
"""

import base64
import json
import os
import sys
import urllib.request

def main():
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
