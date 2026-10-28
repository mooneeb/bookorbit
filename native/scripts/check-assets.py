#!/usr/bin/env python3
"""Check the frozen reader against its reviewed per-file manifest."""
import hashlib
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1]
manifest = json.loads((root / 'dependencies.json').read_text())
for name, expected in manifest['foliate']['files'].items():
    actual = hashlib.sha256((root / 'BookOrbit/Resources/Reader/assets' / name).read_bytes()).hexdigest()
    if actual != expected:
        raise SystemExit(f'Frozen asset changed: {name}')
print(f"Verified {len(manifest['foliate']['files'])} frozen Foliate files")
