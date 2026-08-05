# SPDX-License-Identifier: Unlicense

import argparse
from pathlib import Path

from automation_support import validate_patch


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("encoded", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    args.output.write_bytes(validate_patch(args.encoded.read_text(encoding="utf-8").strip()))
    print("Codex patch policy passed.")
