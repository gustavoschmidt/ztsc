#!/usr/bin/env python3
"""Regenerate the two-panel RSS+wall benchmark charts from a single data table.

Four copies are kept byte-in-sync by this script:
  - docs/benchmarks-light.svg   (standalone, light palette via CSS classes)
  - docs/benchmarks-dark.svg    (standalone, dark palette via CSS classes)
  - docs/index.html             (inline SVG, palette via CSS vars, has data-tip)
  - docs/internals.html         (inline SVG, palette via CSS vars, has data-tip)

Only data-driven attributes/text change; the visual design is untouched. Edit
DATA below (medians: wall = median of 11 monotonic-ns runs, RSS = median of 5
under /usr/bin/time -l, each tool at its own default: ztsc 8 checkers, tsgo 4)
and re-run:

    /usr/bin/python3 docs/gen_charts.py

It also prints derived numbers (ranges, ascii bar chart, ms table) for the
prose in BENCHMARKS.md / README.md.
"""
import math, re, os

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

# name, wall_ztsc, wall_tsgo (ms), rss_ztsc, rss_tsgo (MB)
# ztsc at its default 8 checkers, tsgo at its default 4 checkers.
# Re-measured 2026-07-16 after the default --checkers rose to min(8, cores)
# and the embedded lib blobs were sharded (dom x8, esnext x4). ztsc still
# skips checking its pre-verified lib by default; tsgo checks its lib by
# default — see BENCHMARKS.md for the tsgo --skipDefaultLibCheck parity numbers.
DATA = [
    ("@types/node",        14.8,  46.1, 16.9, 101.4),
    ("@types/react",       23.1, 242.3, 18.2, 186.2),
    ("drizzle-orm",        20.4, 238.1, 23.7, 275.0),
    ("hono",               25.4, 173.9, 22.9, 158.6),
    ("@sinclair/typebox",  16.1,  47.9, 15.2,  77.3),
    ("ajv",                 9.9,  23.6, 10.7,  49.9),
    ("zod",                22.3, 156.1, 17.0, 136.1),
    ("chalk",               6.7,  18.1,  6.7,  43.5),
]

RSS_MAX_PX = 290
WALL_MAX_PX = 270

def rup(x):
    return int(math.floor(x + 0.5))

def pct(a, b):
    return rup(100.0 * a / b)

max_rss_t = max(r[4] for r in DATA)
max_wall_t = max(r[2] for r in DATA)
scale_rss = RSS_MAX_PX / max_rss_t
scale_wall = WALL_MAX_PX / max_wall_t

def w_rss(v):  return rup(v * scale_rss)
def w_wall(v): return rup(v * scale_wall)

# geometry
def rows(fmt):
    """fmt: 'svg' (class-based) or 'html' (fill+data-tip)."""
    out = []
    for i, (name, wz, wt, rz, rt) in enumerate(DATA):
        ytop = 44 + 52 * i          # ztsc bar top
        ybot = 61 + 52 * i          # tsgo bar top
        namey = 64 + 52 * i
        zy = 55 + 52 * i            # ztsc value text baseline
        ty = 72 + 52 * i            # tsgo value text baseline

        wr = w_rss(rz); wtr = w_rss(rt)
        ww = w_wall(wz); wtw = w_wall(wt)
        rpct = pct(rz, rt); wpct = pct(wz, wt)

        out.append('      <text class="t12 dim" x="195" y="%d" text-anchor="end">%s</text>' % (namey, name))
        # left panel: RSS (x=210)
        # right panel: wall (x=620)
        def bar(cls_or_fill, x, y, wdt, tip):
            if fmt == "svg":
                return '      <rect class="%s" x="%d" y="%d" width="%d" height="14" rx="2"/>' % (cls_or_fill, x, y, wdt)
            return '      <rect fill="var(--c-%s)" data-tip="%s" x="%d" y="%d" width="%d" height="14" rx="2"/>' % (cls_or_fill, tip, x, y, wdt)
        def lbl(x, y, txt):
            cls = "bl" if fmt == "svg" else "barlabel"
            return '      <text class="%s" x="%d" y="%d">%s</text>' % (cls, x, y, txt)

        zc = "bz" if fmt == "svg" else "ztsc"
        tc = "bt" if fmt == "svg" else "tsgo"

        # RSS ztsc
        out.append(bar(zc, 210, ytop, wr, "ztsc · %.1f MB · %d%% of tsgo" % (rz, rpct)))
        out.append(lbl(210 + wr + 8, zy, '%d <tspan class="acc">· %d%%</tspan>' % (rup(rz), rpct)))
        # RSS tsgo
        out.append(bar(tc, 210, ybot, wtr, "tsgo 7.0.2 · %.1f MB" % rt))
        out.append(lbl(210 + wtr + 8, ty, '%d' % rup(rt)))
        # wall ztsc
        out.append(bar(zc, 620, ytop, ww, "ztsc · %.1f ms · %d%% of tsgo" % (wz, wpct)))
        out.append(lbl(620 + ww + 8, zy, '%d <tspan class="acc">· %d%%</tspan>' % (rup(wz), wpct)))
        # wall tsgo
        out.append(bar(tc, 620, ybot, wtw, "tsgo 7.0.2 · %.1f ms" % wt))
        out.append(lbl(620 + wtw + 8, ty, '%d' % rup(wt)))
    return "\n".join(out)

def aria():
    rz = [rup(r[3]) for r in DATA]; rt = [rup(r[4]) for r in DATA]
    wz = [rup(r[1]) for r in DATA]; wt = [rup(r[2]) for r in DATA]
    rp = [pct(r[3], r[4]) for r in DATA]; wp = [pct(r[1], r[2]) for r in DATA]
    return ("Two-panel grouped bar chart across eight real packages, each tool at its "
            "own default checker count (ztsc 8, tsgo 4). Left panel, peak resident memory: ztsc uses %d to %d "
            "megabytes, tsgo %d to %d megabytes &#8212; ztsc is %d to %d percent of "
            "tsgo on every package. Right panel, wall clock: ztsc takes %d to %d "
            "milliseconds, tsgo %d to %d milliseconds &#8212; ztsc is %d to %d "
            "percent of tsgo's time." % (
        min(rz), max(rz), min(rt), max(rt), min(rp), max(rp),
        min(wz), max(wz), min(wt), max(wt), min(wp), max(wp)))

HAIRV = '<line class="hairv" x1="590" y1="34" x2="590" y2="442"/>'
ROW_RE = re.compile(
    r'(<line class="hairv" x1="590" y1="34" x2="590" y2="442"/>\n)(.*?)(\n\s+<text class="t11 mut" x="20" y="468")',
    re.DOTALL)
ARIA_RE = re.compile(r'aria-label="Two-panel grouped bar chart.*?percent of tsgo\'s time\."', re.DOTALL)

def patch(path, fmt):
    with open(path, encoding="utf-8") as f:
        text = f.read()
    body = rows(fmt)
    new, n = ROW_RE.subn(lambda m: m.group(1) + "\n" + body + m.group(3), text)
    assert n == 1, "%s: expected 1 row block, got %d" % (path, n)
    new, na = ARIA_RE.subn('aria-label="%s"' % aria(), new)
    assert na == 1, "%s: expected 1 aria-label, got %d" % (path, na)
    with open(path, "w", encoding="utf-8") as f:
        f.write(new)
    print("patched %s (%d rows block, %d aria)" % (os.path.relpath(path, ROOT), n, na))

if __name__ == "__main__":
    patch(os.path.join(HERE, "benchmarks-light.svg"), "svg")
    patch(os.path.join(HERE, "benchmarks-dark.svg"), "svg")
    patch(os.path.join(HERE, "index.html"), "html")
    patch(os.path.join(HERE, "internals.html"), "html")

    print("\n--- derived numbers ---")
    print("aria:", aria())
    rp = [pct(r[3], r[4]) for r in DATA]; wp = [pct(r[1], r[2]) for r in DATA]
    print("RSS pct range: %d-%d%%" % (min(rp), max(rp)))
    print("wall pct range: %d-%d%%" % (min(wp), max(wp)))
    speed = [r[2] / r[1] for r in DATA]
    print("speedup range (all): %.1f-%.1fx" % (min(speed), max(speed)))
    big = [r[2] / r[1] for r in DATA if r[0] not in ("ajv", "chalk")]
    print("speedup range (excl ajv/chalk): %.1f-%.1fx" % (min(big), max(big)))
    print("ztsc floor (esnext-only min wall):", min(r[1] for r in DATA if r[0] in ("chalk","ajv")))
    print("tsgo floor (min wall):", min(r[2] for r in DATA))
    print("\nper-package: name  wall_z/t (pct)  rss_z/t (pct)")
    for name, wz, wt, rz, rt in DATA:
        print("  %-18s %5.1f/%6.1f ms (%2d%%)   %5.1f/%6.1f MB (%2d%%)" % (
            name, wz, wt, pct(wz, wt), rz, rt, pct(rz, rt)))
