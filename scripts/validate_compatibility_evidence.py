# SPDX-License-Identifier: Unlicense

import argparse
import json
from pathlib import Path

from automation_support import validate_evidence


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("path", type=Path)
    parser.add_argument("--steam-build-id")
    parser.add_argument("--executable", choices=("bg3_dx11.exe", "bg3.exe"))
    parser.add_argument("--canonical-output", type=Path)
    args = parser.parse_args()
    value = validate_evidence(
        json.loads(args.path.read_text(encoding="utf-8")),
        args.steam_build_id,
        args.executable,
    )
    if args.canonical_output:
        args.canonical_output.write_text(
            json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n",
            encoding="utf-8",
        )
    print("Compatibility evidence schema passed.")
