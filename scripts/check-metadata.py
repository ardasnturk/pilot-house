#!/usr/bin/env python3
"""Checks metadata/ios against the App Store Connect field limits.

Usage: python3 scripts/check-metadata.py
"""
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent / "metadata" / "ios"
LOCALES = sorted(p.name for p in ROOT.iterdir() if p.is_dir() and p.name != "review_information")
# field -> (limit, unit)
LIMITS = {
    "name.txt": (30, "chars"),
    "subtitle.txt": (30, "chars"),
    "keywords.txt": (100, "bytes"),
    "promotional_text.txt": (170, "chars"),
    "description.txt": (4000, "chars"),
    "release_notes.txt": (4000, "chars"),
    "support_url.txt": (255, "chars"),
    "marketing_url.txt": (255, "chars"),
    "privacy_url.txt": (255, "chars"),
}
# The description must state that the app is independent from Anthropic.
DISCLAIMER = {"en-US": "not affiliated", "tr": "bağlantılı değildir", "de-DE": "keiner Verbindung"}


def main() -> int:
    errors = []
    for locale in LOCALES:
        for field, (limit, unit) in LIMITS.items():
            path = ROOT / locale / field
            if not path.exists():
                errors.append(f"{locale}/{field}: missing")
                continue
            text = path.read_text(encoding="utf-8").strip()
            size = len(text.encode("utf-8")) if unit == "bytes" else len(text)
            if not text:
                errors.append(f"{locale}/{field}: empty")
            elif size > limit:
                errors.append(f"{locale}/{field}: {size} {unit} > {limit}")
            if field == "keywords.txt" and ", " in text:
                errors.append(f"{locale}/{field}: no spaces after commas (they count)")
            print(f"{locale:6} {field:22} {size:5}/{limit} {unit}")
        description = (ROOT / locale / "description.txt").read_text(encoding="utf-8")
        if "github.com/ardasnturk/remote-code" not in description:
            errors.append(f"{locale}/description.txt: must say where to get the Mac app")
        if locale not in DISCLAIMER:
            errors.append(f"{locale}: add its non-affiliation phrase to DISCLAIMER in this script")
        elif DISCLAIMER[locale] not in description:
            errors.append(f"{locale}/description.txt: missing the non-affiliation statement")
    notes = ROOT / "review_information" / "notes.txt"
    if len(notes.read_text(encoding="utf-8")) > 4000:
        errors.append("review_information/notes.txt: > 4000 chars")
    for error in errors:
        print("error:", error, file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
