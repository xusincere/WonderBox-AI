#!/usr/bin/env python3
"""Compile this project's simple string catalogs without requiring full Xcode."""
import json
import pathlib
import plistlib
import sys

source = pathlib.Path(__file__).resolve().parents[1] / "Sources/WonderBox/Resources"
destination = pathlib.Path(sys.argv[1])
for name in ("Localizable", "InfoPlist"):
    catalog = json.loads((source / f"{name}.xcstrings").read_text())
    languages = {}
    for key, entry in catalog["strings"].items():
        for language, localization in entry.get("localizations", {}).items():
            languages.setdefault(language, {})[key] = localization["stringUnit"]["value"]
    for language, strings in languages.items():
        folder = destination / f"{language}.lproj"
        folder.mkdir(parents=True, exist_ok=True)
        (folder / f"{name}.strings").write_bytes(plistlib.dumps(strings))
