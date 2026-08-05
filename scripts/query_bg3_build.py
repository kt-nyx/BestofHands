# SPDX-License-Identifier: Unlicense

import sys
from pathlib import Path

from automation_support import parse_public_build_id


if __name__ == "__main__":
    path = Path(sys.argv[1])
    print(parse_public_build_id(path.read_text(encoding="utf-8", errors="replace")))
