#!/usr/bin/env python3
"""Emit a `--partition-file` for ztsc from a `--dup-profile` dump.

Modes:
  today       replicate src/main.zig's own BFS-order/LPT partition (a control:
              running it through --partition-file must reproduce the baseline)
  contig      one contiguous equal-node-weight BFS range per checker (maximum
              import locality, the "k = 1" the main.zig comment rules out on
              wall clock alone)
  random      equal-node-weight random deal (the locality-free control)
  opt         minimize the c1-measured demand-closure overlap (bench/dup_partition.py)
"""
import sys, random
from dup_partition import load, today_partition, local_search


def contig(files, n):
    items = sorted(files.items())
    total = sum(v[0] for _, v in items)
    part, acc, r = {}, 0, 0
    for fid, (nodes, _) in items:
        acc += nodes
        part[fid] = min(r, n - 1)
        if acc >= total * (r + 1) // n and r + 1 < n:
            r += 1
    return part


def rnd(files, n, seed=7):
    g = random.Random(seed)
    items = sorted(files.items(), key=lambda kv: -kv[1][0])
    load = [0] * n
    part = {}
    order = list(items)
    g.shuffle(order)
    for fid, (nodes, _) in order:
        b = min(range(n), key=lambda k: load[k])
        part[fid] = b
        load[b] += nodes
    return part


def main():
    dump, mode, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
    files, units = load(dump)
    part = {
        "today": lambda: today_partition(files, n),
        "contig": lambda: contig(files, n),
        "random": lambda: rnd(files, n),
        "opt": lambda: local_search(files, units, n, 0.10),
        "optmk": lambda: local_search(files, units, n, 0.10, objective="makespan"),
    }[mode]()
    for fid in sorted(part):
        print(fid, part[fid])


if __name__ == "__main__":
    main()
