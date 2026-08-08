#!/usr/bin/env python3
"""Run a command once and report its wall clock and peak RSS.

    bench/timeit.py <cmd> [args...]   ->  "<wall_seconds> <peak_rss_bytes> <exit_code>"

WHY THIS EXISTS. The other bench scripts read `/usr/bin/time` (-l on macOS,
-v on Linux). That is fine for whole applications, but macOS's `time -l`
prints wall clock with TWO decimals, which floors every millisecond-scale
package row to 0.00-0.01s -- the eight bench/corpus/real packages are simply
not measurable with it. This wrapper brackets the child with
`time.perf_counter()` (nanosecond-resolution monotonic clock) instead, and
takes peak RSS from `resource.getrusage(RUSAGE_CHILDREN).ru_maxrss`, which is
the same kernel counter `/usr/bin/time` reports -- verified byte-identical to
`time -l`'s "maximum resident set size" on this machine.

`ru_maxrss` is the high-water mark over every child this process has reaped.
The wrapper spawns exactly one child and exits, so it is that child's peak.
Units differ by platform: bytes on Darwin, kilobytes on Linux (and everywhere
else glibc-ish), normalized to bytes here.

COST. Wrapping costs a python3 interpreter start plus a fork/exec, ~1.6 ms on
an M4. That floor is paid by BOTH legs of every comparison, so the ratios the
project's bars are stated in are unaffected; only the absolute millisecond
figures for the very smallest packages carry it. bench/matrix.sh measures the
floor at the top of every run and records it in the results header.

The child's stdout and stderr are discarded: ztsc and tsgo both print
diagnostics, we only want the numbers. The child's exit status is REPORTED,
never propagated -- ztsc exits nonzero whenever it reports a diagnostic, and a
caller running under `set -e`/`pipefail` would otherwise die mid-measurement.
This wrapper exits 0 unless it could not spawn the child at all.
"""

import resource
import subprocess
import sys
import time


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        sys.stderr.write(__doc__)
        return 2

    start = time.perf_counter()
    try:
        code = subprocess.call(
            argv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        )
    except OSError as err:
        sys.stderr.write("timeit.py: cannot run %s: %s\n" % (argv[0], err))
        return 127
    wall = time.perf_counter() - start

    # Darwin reports ru_maxrss in bytes, Linux in kilobytes.
    unit = 1 if sys.platform == "darwin" else 1024
    peak = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss * unit

    print("%.6f %d %d" % (wall, peak, code))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
