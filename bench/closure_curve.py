#!/usr/bin/env python3
"""Emit a partition that measures the DEMAND-CLOSURE CURVE in one run.

Checker k owns 2**k of the program's costliest files (k = 0..n-2) and the
last checker owns the remainder. Checkers do not share a type store, so
`--memory`'s per-checker `types` line then reads out, from a single run,
how a checker's materialized type count grows with the number of files it
owns — the law that decides whether partitioning can divide the work at all.

Usage:  bench/closure_curve.py <dup dump> <n_checkers> > part.txt
"""
import sys
from dup_partition import load


def main():
    dump, n = sys.argv[1], int(sys.argv[2])
    files, _ = load(dump)
    order = sorted(files, key=lambda f: (-files[f][0], f))  # costliest first
    part, i = {}, 0
    for k in range(n - 1):
        for _ in range(2 ** k):
            if i < len(order):
                part[order[i]] = k
                i += 1
    for f in order[i:]:
        part[f] = n - 1
    for f in sorted(part):
        print(f, part[f])
    counts = [sum(1 for f in part if part[f] == k) for k in range(n)]
    print(f"# files per checker: {counts}", file=sys.stderr)


if __name__ == "__main__":
    main()
