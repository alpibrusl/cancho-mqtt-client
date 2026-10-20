#!/usr/bin/env python3
"""Gate 8 (design section 9): no source file over 2,000 lines."""
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
LIMIT = 2000
bad = [(p, n) for p in ROOT.rglob("*") if p.is_file() and p.suffix in (".cho", ".py", ".md", ".sh") and ".git" not in p.parts
       for n in [sum(1 for _ in p.open(errors="replace"))] if n > LIMIT]
for p, n in bad:
    print(f"{p.relative_to(ROOT)}: {n} lines (limit {LIMIT})")
print("lines: " + ("FAIL" if bad else "ok"))
sys.exit(1 if bad else 0)
