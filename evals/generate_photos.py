"""Generate the realistic eval photos with a Gemini image model ("Nano Banana").

    uv run python -m evals.generate_photos [--model gemini-3-pro-image] [--only id1,id2] [--force]

Needs a Gemini key with billing: image models have no free-tier quota. Writes evals/realistic/<id>.png.
Look at every image afterwards and add its id to VERIFIED in evals/realistic.py only if the printed
values match the case labels.
"""

import argparse
import sys
from pathlib import Path

from google import genai
from google.genai import types

from evals.realistic import GENERATED
from vault.config import get_settings

OUT = Path(__file__).parent / "realistic"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", default="gemini-3-pro-image")
    parser.add_argument("--only", help="comma-separated case ids")
    parser.add_argument("--force", action="store_true", help="regenerate existing images")
    args = parser.parse_args()
    client = genai.Client(api_key=get_settings().gemini_api_key)
    OUT.mkdir(exist_ok=True)
    for case in GENERATED:
        path = OUT / f"{case['id']}.png"
        if (args.only and case["id"] not in args.only.split(",")) or (path.exists() and not args.force):
            continue
        response = client.models.generate_content(
            model=args.model,
            contents=case["prompt"],
            config=types.GenerateContentConfig(response_modalities=["IMAGE"]),
        )
        parts = [p for p in (response.candidates[0].content.parts if response.candidates else []) if p.inline_data]
        if not parts:
            print(f"{case['id']}: no image returned", file=sys.stderr)
            continue
        path.write_bytes(parts[0].inline_data.data)
        print(f"{case['id']}: {path.name}", file=sys.stderr)


if __name__ == "__main__":
    main()
