"""Print a Dart source file with line numbers.

Usage (cwd = apps/mobile):
  python tool/dump_dart.py lib/features/inventory/data/inventory_models.dart
  python tool/dump_dart.py features/inventory/data/inventory_models.dart
  python tool/dump_dart.py C:/Users/PC/.../inventory_models.dart

Pure stdlib; avoids the display glitches seen with other tooling.
"""

import os
import sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: python tool/dump_dart.py <path>", file=sys.stderr)
        return 2

    raw = sys.argv[1].replace("/", "\\")
    if os.path.isabs(raw):
        path = raw
    elif "\\lib\\" in raw:
        path = raw
    else:
        path = "lib\\" + raw

    with open(path, "r", encoding="utf-8") as fh:
        lines = fh.readlines()

    width = len(str(len(lines)))
    for i, line in enumerate(lines, start=1):
        print(f"{i:>{width}}: {line}", end="")
    print(f"\n--- {len(lines)} lines ---")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
