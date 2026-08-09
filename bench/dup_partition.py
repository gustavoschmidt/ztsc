#!/usr/bin/env python3
"""How much of ztsc's cross-checker work duplication is a PARTITION problem?

Reads the `-- DUPDATA v1 --` block a `--dup-profile --checkers=1` run writes to
stderr (see the cross-checker duplication section of `src/checker/prof.zig`)
and answers, for a given checker count:

  * what the DISTINCT declaration work is (the 1x floor);
  * what today's partition (`src/main.zig`'s BFS-order / LPT split, replicated
    here exactly) actually pays for it, as a total and as a makespan;
  * what the BEST partition could pay — a lower bound that no partition can
    beat, and the best one a strong local search actually finds;
  * and the single number that decides the lane: the makespan floor
    `max_f closure(f)`, the declaration cost of the most expensive single
    file's demand closure. Every partition puts that file somewhere, and
    whichever part holds it pays its whole closure, so no partition of any
    shape gets the declaration phase below it.

Usage:  bench/dup_partition.py <dump> [n_checkers]
"""

import sys
import random
from math import ceil

COST = "visits"  # "visits" (contention-insensitive) or "ns"


def load(path):
    files = {}       # fid -> (nodes, path)
    units = []       # (cost_ns, cost_visits, [fids], kind, asks)
    inblock = False
    for line in open(path, errors="replace"):
        if line.startswith("-- DUPDATA"):
            inblock = True
            continue
        if line.startswith("-- END DUPDATA"):
            break
        if not inblock:
            continue
        p = line.split()
        if p[0] == "F":
            files[int(p[1])] = (int(p[2]), p[3] if len(p) > 3 else "")
        elif p[0] == "K":
            # K <key> <kind> <self_ns> <self_visits> <builds> <asks> <nf> f...
            kind, ns, visits, builds, asks, nf = p[2], int(p[3]), int(p[4]), int(p[5]), int(p[6]), int(p[7])
            fids = [int(x) for x in p[8:8 + nf]]
            units.append((ns, visits, fids, kind, asks))
    return files, units


def cost_of(u):
    return u[1] if COST == "visits" else u[0]


def today_partition(files, n):
    """Replicate src/main.zig's partition exactly: file ids in ascending
    (BFS-renumbered) order, cut into 2n equal-node-weight runs, dealt
    longest-first onto the least-loaded checker."""
    items = sorted(files.items())                      # (fid, (nodes, path))
    total = sum(v[0] for _, v in items)
    runs, acc, base, start, r = [], 0, 0, 0, 0
    n_runs = n * 2
    for idx, (_fid, (nodes, _p)) in enumerate(items):
        acc += nodes
        if acc >= total * (r + 1) // n_runs and r + 1 < n_runs:
            runs.append((start, idx + 1, acc - base))
            base, start, r = acc, idx + 1, r + 1
    if start < len(items):
        runs.append((start, len(items), acc - base))
    runs.sort(key=lambda x: (-x[2], x[0]))
    loads = [0] * n
    part = {}
    for s, e, c in runs:
        b = min(range(n), key=lambda k: (loads[k], k))
        for fid, _ in items[s:e]:
            part[fid] = b
        loads[b] += c
    return part


def evaluate(part, units, n):
    """(total cost paid, per-part cost) for a file->part map."""
    per = [0] * n
    for u in units:
        c = cost_of(u)
        seen = set()
        for f in u[2]:
            seen.add(part[f])
        for p in seen:
            per[p] += c
    return sum(per), per


def local_search(files, units, n, tol, seconds_budget_passes=6, seed=1,
                 objective="total"):
    """Greedy seed + repeated single-file moves that reduce cost while keeping
    node-weight balance inside `tol`. `objective` is "total" (aggregate work,
    the RSS proxy) or "makespan" (the wall proxy). Returns the best file->part
    map found; its cost is an UPPER bound on the optimum."""
    rnd = random.Random(seed)
    fids = list(files.keys())
    w = {f: files[f][0] for f in fids}
    total_w = sum(w.values())
    cap = (total_w / n) * (1 + tol)

    # nets touching each file
    nets_of = {f: [] for f in fids}
    for i, u in enumerate(units):
        for f in u[2]:
            nets_of[f].append(i)
    ncost = [cost_of(u) for u in units]

    best = None
    for attempt in range(3):
        # Seed: greedily place files (largest closure first) where they add
        # least new net cost, subject to the cap.
        order = sorted(fids, key=lambda f: -sum(ncost[i] for i in nets_of[f]))
        if attempt:
            rnd.shuffle(order)
        part = {}
        load = [0.0] * n
        pcost = [0] * n              # closure cost currently carried by a part
        # count[net][p] = how many files of that net are in part p
        cnt = [[0] * n for _ in units]
        for f in order:
            bestp, bestd = None, None
            for p in range(n):
                if load[p] + w[f] > cap:
                    continue          # HARD cap: never violate the balance
                d = sum(ncost[i] for i in nets_of[f] if cnt[i][p] == 0)
                if objective == "makespan":
                    d = pcost[p] + d  # prefer the part that stays cheapest
                if bestd is None or d < bestd or (d == bestd and load[p] < load[bestp]):
                    bestp, bestd = p, d
            if bestp is None:         # every part is full: fall back to lightest
                bestp = min(range(n), key=lambda k: load[k])
            part[f] = bestp
            load[bestp] += w[f]
            for i in nets_of[f]:
                if cnt[i][bestp] == 0:
                    pcost[bestp] += ncost[i]
                cnt[i][bestp] += 1

        def score():
            return max(pcost) if objective == "makespan" else sum(pcost)

        # Refine: move a file to the part that improves the objective most.
        for _ in range(seconds_budget_passes):
            moved = 0
            for f in sorted(fids, key=lambda x: -w[x]):
                cur = part[f]
                gone = sum(ncost[i] for i in nets_of[f] if cnt[i][cur] == 1)
                base = score()
                bestp, bestscore = cur, base
                for p in range(n):
                    if p == cur or load[p] + w[f] > cap:
                        continue
                    add = sum(ncost[i] for i in nets_of[f] if cnt[i][p] == 0)
                    trial = list(pcost)
                    trial[cur] -= gone
                    trial[p] += add
                    s = max(trial) if objective == "makespan" else sum(trial)
                    if s < bestscore:
                        bestp, bestscore = p, s
                if bestp != cur:
                    add = sum(ncost[i] for i in nets_of[f] if cnt[i][bestp] == 0)
                    pcost[cur] -= gone
                    pcost[bestp] += add
                    for i in nets_of[f]:
                        cnt[i][cur] -= 1
                        cnt[i][bestp] += 1
                    load[cur] -= w[f]
                    load[bestp] += w[f]
                    part[f] = bestp
                    moved += 1
            if not moved:
                break
        tot, per = evaluate(part, units, n)
        s = max(per) if objective == "makespan" else tot
        if best is None or s < best[0]:
            best = (s, dict(part))
    return best[1]


def main():
    path = sys.argv[1]
    n = int(sys.argv[2]) if len(sys.argv) > 2 else 4
    files, units = load(path)
    distinct = sum(cost_of(u) for u in units)
    print(f"files: {len(files)}   declaration units: {len(units)}   cost axis: {COST}")
    print(f"distinct declaration work (1x floor): {distinct:,}")

    # --- the makespan floor, which is the number that decides the lane -----
    closure = {f: 0 for f in files}
    for u in units:
        c = cost_of(u)
        for f in u[2]:
            closure[f] += c
    worst = max(closure, key=closure.get)
    print(f"\nmakespan floor  max_f closure(f) = {closure[worst]:,} "
          f"({100.0*closure[worst]/distinct:.1f}% of the distinct total)")
    print(f"  worst file: {files[worst][1]}")
    top = sorted(closure.items(), key=lambda kv: -kv[1])[:8]
    for f, c in top:
        print(f"    {c:>12,}  {100.0*c/distinct:5.1f}%  {files[f][1]}")

    # --- how wide are the nets, cost-weighted -----------------------------
    print("\ncost-weighted net-size histogram (how many files demand a unit)")
    buckets = [(1, 1), (2, 4), (5, 16), (17, 64), (65, 160), (161, 320), (321, 10**9)]
    for lo, hi in buckets:
        c = sum(cost_of(u) for u in units if lo <= len(u[2]) <= hi)
        label = f"{lo}-{hi}" if hi < 10**9 else f"{lo}+"
        print(f"  {label:>9} files: {c:>13,}  {100.0*c/distinct:5.1f}%")

    # --- rigorous lower bound under a balance model -----------------------
    weights = sorted(v[0] for v in files.values())
    total_w = sum(weights)
    for tol in (0.0, 0.10, 0.25, 0.50):
        cap = (total_w / n) * (1 + tol)
        k, acc = 0, 0
        for x in weights:
            if acc + x > cap:
                break
            acc += x
            k += 1
        lb = sum(cost_of(u) * max(1, ceil(len(u[2]) / max(1, k))) for u in units)
        print(f"\nbalance tol {tol:+.0%}: a part holds at most {k} files "
              f"=> LOWER BOUND on total = {lb:,}  ({lb/distinct:.2f}x distinct)")

    # --- today's partition -------------------------------------------------
    part = today_partition(files, n)
    tot, per = evaluate(part, units, n)
    sizes = [sum(1 for f in part if part[f] == p) for p in range(n)]
    print(f"\ntoday's partition (main.zig BFS+LPT), n={n}: files per checker {sizes}")
    print(f"  total {tot:,}  ({tot/distinct:.2f}x distinct)   makespan {max(per):,} "
          f"({100.0*max(per)/distinct:.1f}% of distinct)")
    print(f"  per checker: {[f'{x:,}' for x in per]}")

    # --- best found --------------------------------------------------------
    for tol in (0.10, 0.50):
        bp = local_search(files, units, n, tol)
        btot, bper = evaluate(bp, units, n)
        bsizes = [sum(1 for f in bp if bp[f] == p) for p in range(n)]
        bw = [sum(files[f][0] for f in bp if bp[f] == p) for p in range(n)]
        print(f"\nbest partition found (tol {tol:+.0%}): files {bsizes}  nodes {bw}")
        print(f"  total {btot:,}  ({btot/distinct:.2f}x distinct)   makespan {max(bper):,} "
              f"({100.0*max(bper)/distinct:.1f}% of distinct)")
        print(f"  per checker: {[f'{x:,}' for x in bper]}")
        print(f"  vs today: total {100.0*btot/tot-100:+.1f}%   makespan {100.0*max(bper)/max(per)-100:+.1f}%")


if __name__ == "__main__":
    main()
