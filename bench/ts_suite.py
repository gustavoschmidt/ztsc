#!/usr/bin/env python3
"""Divergence sweep over Microsoft's TypeScript test corpus: ztsc vs tsgo.

Driven by bench/ts_suite.sh (which builds the ReleaseFast binary and locates
the pinned oracle); this file is the engine. See bench/fetch_ts_suite.sh for
the corpus pin and the licensing rationale (the corpus is fetched, never
committed).

WHAT THIS IS
------------
The TypeScript repo's tests/cases/{compiler,conformance} are ~12k hand-written
single- or multi-file programs, each carrying `// @option: value` pragmas that
the upstream harness turns into compiler options. This script reproduces enough
of that harness to materialize every case as a real directory with a real
tsconfig.json, runs BOTH compilers over it, and diffs their diagnostics. It is
a discovery tool: the output is a prioritized queue of ztsc/tsgo divergences,
not a pass/fail gate.

THE INVARIANT
-------------
ztsc and tsgo always run against the IDENTICAL case directory and the IDENTICAL
tsconfig.json, from the same working directory. Pragma translation is therefore
allowed to be lossy (and is — see NORMALIZATION), because a mistranslation
moves both compilers the same way; what it must never do is hand the two tools
different inputs. Every case that cannot be represented at all is SKIPPED and
COUNTED by category — nothing is dropped silently.

NORMALIZATION (default mode; --faithful passes these through instead)
---------------------------------------------------------------------
ztsc is a strict-only checker that accepts-and-ignores `target`, `module` and
`moduleResolution`, and whose `lib` is coarse (any `es*` token selects the whole
embedded ES-core..esnext blob, any `dom*` token the DOM blob — src/libs.zig).
The upstream suite is written for the tsc defaults: non-strict, `target: es5`,
`module: commonjs`. Running it verbatim would compare a strict checker against a
non-strict oracle and drown the report in known, deliberate design differences.
So every generated tsconfig pins the same base:

    strict: true, target: esnext, module: esnext, moduleResolution: bundler,
    lib: [esnext, dom, dom.iterable, dom.asynciterable], noEmit: true

and `@target`/`@module`/`@moduleResolution`/`@lib` pragmas are dropped (counted
as normalized). Each of those pins was measured, not guessed:

  - `module: esnext` + `moduleResolution: bundler` is the format ztsc behaves
    as if it were in. It reports TS1202/TS1203 on `import x = require()` /
    `export =` unconditionally, so pinning the oracle to ESM turned 46 of a
    200-case smoke run's 111 excess keys into agreement (43.6% -> 59.6% match).
  - the explicit `lib` list is exactly ztsc's embedded blob; tsgo's default for
    `target: esnext` is lib.esnext.FULL, which adds ScriptHost and
    WebWorker.ImportScripts globals ztsc does not ship.
  - `useDefineForClassFields: false` was tried (ztsc reports no TS2612) and is
    NOT pinned: on a 3000-case subset it moved the match rate by -0.1pt.

Cases whose pragmas would turn strictness OFF, or that set an option ztsc does
not implement (so the oracle would honor it and ztsc would not), are skipped
rather than silently mistranslated.

Three more fidelity repairs, each found by reading a divergence class and
tracing it back to this file rather than to the checker:

  - 844 cases carry a UTF-8 BOM, which hid a line-1 pragma from `^//`;
  - 7 cases are UTF-16, and decoding them as UTF-8 produced mojibake that both
    tools then scanned differently (~800 phantom TS2304s);
  - 163 cases reference React typings through the upstream harness's virtual
    `/.lib` mount, which does not exist on a real filesystem (~430 phantom
    TS7026s).

USAGE
-----
    bench/ts_suite.sh                     # full sweep
    bench/ts_suite.sh --limit 300         # smoke run
    bench/ts_suite.sh --filter conformance/types
    bench/ts_suite.sh --jobs 8 --timeout 20
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
from collections import Counter
from concurrent.futures import ThreadPoolExecutor

# --------------------------------------------------------------- pragma tables

# `// @name: value`, at the start of a line, anywhere in the file (this is the
# upstream harness's optionRegex, applied line by line).
OPTION_RE = re.compile(r"^//\s*@([A-Za-z]\w*)\s*:\s*(.*?)\s*$")

# Base options every generated tsconfig pins (see NORMALIZATION).
BASE_OPTIONS = {
    "strict": True,
    "target": "esnext",
    "module": "esnext",
    "moduleResolution": "bundler",
    "noEmit": True,
    # ztsc's embedded lib is exactly the upstream esnext reference chain plus
    # lib.dom + dom.iterable + dom.asynciterable (NOTICE §1). tsgo's default for
    # `target: esnext` is lib.esnext.full, which additionally brings ScriptHost
    # and WebWorker.ImportScripts — naming the set keeps both compilers on the
    # same globals instead of manufacturing TS2304s for `ActiveXObject` etc.
    "lib": ["esnext", "dom", "dom.iterable", "dom.asynciterable"],
}

# Pragmas normalized away by the base options above (counted, never skipped).
NORMALIZED = {"target", "module", "moduleresolution", "lib"}

# Pragmas that are pure emit/harness metadata: dropped, case still runs.
IGNORED = {
    "declaration", "declarationmap", "declarationdir", "emitdeclarationonly",
    "noemit", "noemithelpers", "noemitonerror", "outdir", "outfile", "rootdir",
    "sourcemap", "inlinesourcemap", "inlinesources", "maproot", "sourceroot",
    "removecomments", "stripinternal", "preserveconstenums", "incremental",
    "composite", "tsbuildinfofile", "newline", "emitbom", "listfilesonly",
    "pretty", "suppressoutputpathcheck", "fullemitpaths", "notypesandsymbols",
    "traceresolution", "noimplicitreferences", "typescriptversion",
    "ignoredeprecations", "capturesuggestions", "stabletypeordering",
    "reportdiagnostics", "baselinefile", "noerrortruncation", "filename",
    "moduleresolutionmode", "includebuiltfile", "libfiles", "nolibcheck",
}

# Pragmas translated verbatim into compilerOptions (both tools implement them).
PASSTHROUGH_BOOL = {
    "noimplicitany": "noImplicitAny",
    "experimentaldecorators": "experimentalDecorators",
    "emitdecoratormetadata": "emitDecoratorMetadata",
    "esmoduleinterop": "esModuleInterop",
    "allowsyntheticdefaultimports": "allowSyntheticDefaultImports",
    "resolvejsonmodule": "resolveJsonModule",
    "skiplibcheck": "skipLibCheck",
    "skipdefaultlibcheck": "skipDefaultLibCheck",
    "nouncheckedsideeffectimports": "noUncheckedSideEffectImports",
    "resolvepackagejsonexports": "resolvePackageJsonExports",
    "resolvepackagejsonimports": "resolvePackageJsonImports",
}
PASSTHROUGH_STR = {
    "jsx": "jsx",
    "jsxfactory": "jsxFactory",
    "jsxfragmentfactory": "jsxFragmentFactory",
    "jsximportsource": "jsxImportSource",
    "baseurl": "baseUrl",
}
PASSTHROUGH_LIST = {
    "types": "types",
    "typeroots": "typeRoots",
    "modulesuffixes": "moduleSuffixes",
}

# The strict family. Under the forced `strict: true` base an explicit `true` is
# a no-op (case runs); an explicit `false` would need a non-strict checker, so
# the case is skipped.
STRICT_FAMILY = {
    "strict", "strictnullchecks", "strictfunctiontypes",
    "strictpropertyinitialization", "strictbindcallapply",
    "strictbuiltiniteratorreturn", "noimplicitthis", "alwaysstrict",
    "useunknownincatchvariables",
}
# Same idea, inverted sense: `true` loosens, so `true` is the skip.
STRICT_FAMILY_INVERTED = {"nostrictgenericchecks"}

# Options tsgo honors that ztsc does not implement. Translating them would hand
# the oracle a rule ztsc never sees, so the case is skipped and counted by name.
UNSUPPORTED = {
    "nounusedlocals", "nounusedparameters", "noimplicitreturns",
    "nofallthroughcasesinswitch", "noimplicitoverride",
    "nopropertyaccessfromindexsignature", "nouncheckedindexedaccess",
    "exactoptionalpropertytypes", "usedefineforclassfields",
    "downleveliteration", "isolatedmodules", "verbatimmodulesyntax",
    "isolateddeclarations", "erasablesyntaxonly", "allowunreachablecode",
    "allowunusedlabels", "moduledetection", "customconditions",
    "allowimportingtsextensions", "allowarbitraryextensions",
    "rewriterelativeimportextensions", "nocheck", "maxnodemodulejsdepth",
    "allowumdglobalaccess", "rootdirs", "importhelpers", "reactnamespace",
    "paths", "usedefineforclassfields",
}

# Harness features with no tsconfig representation (virtual FS layout, symlinks,
# a different cwd, case-insensitive FS emulation, no default lib, ...).
HARNESS_ONLY = {
    "currentdirectory", "symlink", "link", "usecasesensitivefilenames",
    "noresolve", "preservesymlinks", "nolib", "libreplacement",
}

# Removed from the compiler by TS 7 — the oracle answers with a config error.
REMOVED = {
    "keyofstringsonly", "suppressimplicitanyindexerrors",
    "suppressexcesspropertyerrors", "importsnotusedasvalues",
    "preservevalueimports", "noimplicitusestrict", "out", "charset",
    "prepend", "target:es3",
}

# JS checking: ztsc never parses JS.
JS_PRAGMAS = {"allowjs", "checkjs"}

TS_EXT = (".ts", ".tsx", ".mts", ".cts", ".d.ts")
JS_EXT = (".js", ".jsx", ".mjs", ".cjs")

# 163 cases pull React typings with `/// <reference path="/.lib/react.d.ts" />`.
# Upstream those live in tests/lib, mounted at the virtual-FS root as `/.lib`.
# On a real filesystem that absolute path resolves to nothing, so both tools
# would lose the React types and every such case would show up as a JSX
# divergence (TS7026 "no interface JSX.IntrinsicElements") that is entirely the
# harness's fault. The files are staged into the case dir as `_lib/` and the
# reference rewritten to point at them — the same text for both compilers.
VIRTUAL_LIB = "/.lib/"
STAGED_LIB = "_lib"
LIB_SOURCE: str = ""  # set from --corpus in main()

# ------------------------------------------------------------ case extraction


class Skip(Exception):
    def __init__(self, category: str):
        super().__init__(category)
        self.category = category


def parse_bool(v: str):
    s = v.strip().lower()
    if s in ("true", ""):
        return True
    if s in ("false",):
        return False
    return None


def split_units(text: str, default_name: str):
    """Reproduce the harness's `makeUnitsFromTest` file split.

    Returns (units, options) where units is [(name, content)] in declaration
    order and options is {lowercased pragma: raw value} (last wins).
    """
    units: list[tuple[str, str]] = []
    options: dict[str, str] = {}
    name = None
    buf: list[str] = []

    for line in text.split("\n"):
        m = OPTION_RE.match(line)
        if m:
            key = m.group(1).lower()
            val = m.group(2)
            if key == "filename":
                if name is not None or "".join(buf).strip():
                    units.append((name or default_name, "\n".join(buf)))
                name = val.strip()
                buf = []
                continue
            options[key] = val
        buf.append(line)

    if name is not None or "".join(buf).strip():
        units.append((name or default_name, "\n".join(buf)))
    return units, options


def normalize_unit_path(raw: str) -> str:
    p = raw.replace("\\", "/").strip()
    while p.startswith("/"):
        p = p[1:]
    p = os.path.normpath(p)
    if p.startswith("..") or os.path.isabs(p):
        raise Skip("filename_escapes_case_dir")
    return p


def plan_case(test_path: str, faithful: bool):
    """Turn a corpus test file into (files, tsconfig, notes) or raise Skip."""
    with open(test_path, "rb") as f:
        raw = f.read()
    # Seven cases are UTF-16 (tsc reads them natively). Decoding them as UTF-8
    # produced mojibake that both tools then scanned differently — ~800 phantom
    # TS2304s. Decode by BOM and re-emit as UTF-8: same program, one encoding.
    if raw[:2] in (b"\xff\xfe", b"\xfe\xff"):
        text = raw.decode("utf-16")
        notes_encoding = ["utf16_source"]
    else:
        text = raw.decode("utf-8", errors="surrogateescape")
        notes_encoding = []
    # 844 of the ~12.4k cases start with a UTF-8 BOM, and ~a third of those put
    # a pragma on line 1 — without stripping it the `^//` match fails and the
    # case runs with the wrong options (this silently ran `@strict: false`
    # tests under the forced strict base until it was caught).
    text = text.lstrip("﻿")

    default_name = os.path.basename(test_path)
    units, options = split_units(text, default_name)
    if not units:
        raise Skip("empty_test")

    notes: list[str] = list(notes_encoding)
    opts = dict(BASE_OPTIONS)

    for key, val in options.items():
        if key in IGNORED:
            continue
        if key in JS_PRAGMAS:
            raise Skip("js_case")
        if key in HARNESS_ONLY:
            raise Skip(f"harness_only:{key}")
        if key in REMOVED:
            raise Skip(f"removed_in_ts7:{key}")
        if key in UNSUPPORTED:
            raise Skip(f"unsupported_option:{key}")
        if key in NORMALIZED:
            if faithful:
                _apply_faithful(opts, key, val)
            else:
                notes.append(f"normalized:{key}")
            continue
        # A comma in a scalar option is the harness's "run this test once per
        # value" permutation syntax (`@strict: true, false`). Only the first
        # permutation is run — counted, and identical for both tools. List
        # options (types/typeRoots/...) keep their commas.
        if "," in val and key not in PASSTHROUGH_LIST:
            val = val.split(",")[0]
            notes.append(f"multi_permutation_first:{key}")

        if key in STRICT_FAMILY:
            b = parse_bool(val)
            if b is False:
                raise Skip(f"strict_off:{key}")
            if b is None:
                raise Skip(f"unparsable_value:{key}")
            continue
        if key in STRICT_FAMILY_INVERTED:
            if parse_bool(val) is not False:
                raise Skip(f"strict_off:{key}")
            continue
        if key in PASSTHROUGH_BOOL:
            b = parse_bool(val)
            if b is None:
                raise Skip(f"unparsable_value:{key}")
            opts[PASSTHROUGH_BOOL[key]] = b
            continue
        if key in PASSTHROUGH_STR:
            opts[PASSTHROUGH_STR[key]] = val.strip()
            continue
        if key in PASSTHROUGH_LIST:
            opts[PASSTHROUGH_LIST[key]] = [
                x.strip() for x in val.split(",") if x.strip()
            ]
            continue
        raise Skip(f"unknown_pragma:{key}")

    # Materialized files, deduplicated by path (last declaration wins, as the
    # harness does), order preserved for the tsconfig `files` list — ztsc's
    # answer is root-file-order sensitive (bench/order_sweep.sh), so the order
    # must be the test's own, and identical for both tools.
    seen: dict[str, str] = {}
    order: list[str] = []
    for raw, content in units:
        p = normalize_unit_path(raw)
        if p not in seen:
            order.append(p)
        seen[p] = content

    if any(p.lower().endswith(JS_EXT) for p in order):
        raise Skip("js_case")

    # A case that ships its own tsconfig.json/jsconfig.json is a config-file
    # test; the generated project would overwrite it, so the case is not
    # representable here.
    if any(os.path.basename(p).lower() in ("tsconfig.json", "jsconfig.json")
           for p in order):
        raise Skip("declares_own_tsconfig")

    roots = [p for p in order if p.lower().endswith(TS_EXT)]
    if not roots:
        raise Skip("no_ts_inputs")

    # .tsx needs a `jsx` option or every case is one TS17004; the suite's .tsx
    # tests usually carry @jsx, and when they do not both tools get the same
    # default here.
    if any(p.lower().endswith(".tsx") for p in order) and "jsx" not in opts:
        opts["jsx"] = "preserve"
        notes.append("jsx_defaulted")

    files = [(p, seen[p]) for p in order]
    if any(VIRTUAL_LIB in c for _, c in files):
        rewritten = []
        for p, c in files:
            if VIRTUAL_LIB in c:
                to_lib = os.path.relpath(STAGED_LIB, os.path.dirname(p) or ".")
                c = c.replace(VIRTUAL_LIB, to_lib + "/")
            rewritten.append((p, c))
        files = rewritten
        for name in ("react.d.ts", "react16.d.ts",
                     "react18/react18.d.ts", "react18/global.d.ts"):
            src = os.path.join(LIB_SOURCE, name)
            if os.path.exists(src):
                with open(src, "r", encoding="utf-8",
                          errors="surrogateescape") as f:
                    files.append((f"{STAGED_LIB}/{name}", f.read()))
        notes.append("staged_virtual_lib")

    tsconfig = {"compilerOptions": opts, "files": roots}
    return files, tsconfig, notes


def _apply_faithful(opts: dict, key: str, val: str):
    v = val.strip()
    if key == "lib":
        opts["lib"] = [x.strip() for x in v.split(",") if x.strip()]
        return
    if "," in v:
        v = v.split(",")[0].strip()
    opts[{"target": "target", "module": "module",
          "moduleresolution": "moduleResolution"}[key]] = v
    if key == "module" and v.lower() in ("commonjs", "amd", "umd", "system"):
        opts.pop("moduleResolution", None)


# ----------------------------------------------------------------- execution

ZTSC_DIAG = re.compile(r"^(.*?):(\d+):(\d+): error (TS\d+):")
TSGO_DIAG = re.compile(r"^(.*?)\((\d+),(\d+)\): error (TS\d+):")
GLOBAL_DIAG = re.compile(r"^error (TS\d+):")
# ztsc's parse-phase diagnostics carry no TS code ("a.ts:3:5: error: expected an
# expression"). They matter for bucketing, not for keys — see run_case.
ZTSC_UNCODED = re.compile(r"^(.*?):(\d+):(\d+): error: ")


def keys_from(out: str, tsgo: bool):
    """-> (diagnostic keys, count of ztsc parse-phase/uncoded diagnostics)."""
    ks = set()
    uncoded = 0
    diag = TSGO_DIAG if tsgo else ZTSC_DIAG
    for line in out.split("\n"):
        m = diag.match(line)
        if m:
            path = m.group(1).replace("\\", "/")
            if path.startswith("./"):
                path = path[2:]
            ks.add(f"{path}:{m.group(2)}:{m.group(3)}:{m.group(4)}")
            continue
        m = GLOBAL_DIAG.match(line)
        if m:
            ks.add(f"(config):0:0:{m.group(1)}")
            continue
        if not tsgo and ZTSC_UNCODED.match(line):
            uncoded += 1
    return ks, uncoded


def run_tool(cmd: list[str], cwd: str, timeout: float):
    try:
        p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True,
                           timeout=timeout, errors="replace")
    except subprocess.TimeoutExpired:
        return None, "timeout", ""
    out = (p.stdout or "") + (p.stderr or "")
    return p.returncode, None, out


def run_case(args, test_path: str, rel: str):
    res = {"case": rel, "status": "ok"}
    try:
        files, tsconfig, notes = plan_case(test_path, args.faithful)
    except Skip as s:
        res["status"] = "skip"
        res["category"] = s.category
        return res
    except Exception as e:  # unreadable / undecodable test file
        res["status"] = "skip"
        res["category"] = f"plan_error:{type(e).__name__}"
        return res

    res["notes"] = notes
    case_dir = os.path.join(args.work, rel[:-len(os.path.splitext(rel)[1])])
    if os.path.isdir(case_dir):
        shutil.rmtree(case_dir)
    os.makedirs(case_dir, exist_ok=True)
    for p, content in files:
        full = os.path.join(case_dir, p)
        os.makedirs(os.path.dirname(full) or case_dir, exist_ok=True)
        with open(full, "w", encoding="utf-8", errors="surrogateescape") as f:
            f.write(content)
    with open(os.path.join(case_dir, "tsconfig.json"), "w") as f:
        json.dump(tsconfig, f, indent=2)

    zrc, zerr, zout = run_tool(
        [args.ztsc, "--pretty=false", "--checkers=1", "--workers=1",
         "-p", "tsconfig.json"], case_dir, args.timeout)
    trc, terr, tout = run_tool(
        [args.tsgo, "--pretty", "false", "-p", "tsconfig.json"],
        case_dir, args.timeout)

    if zerr == "timeout":
        res["status"] = "ztsc_timeout"
        return res
    if terr == "timeout":
        res["status"] = "tsgo_timeout"
        return res
    if zrc not in (0, 1):
        res["status"] = "ztsc_crash"
        res["detail"] = f"exit {zrc}: " + " | ".join(
            l for l in zout.split("\n") if l.strip())[:300]
        return res
    if trc not in (0, 1, 2):
        res["status"] = "tsgo_crash"
        res["detail"] = f"exit {trc}: " + " | ".join(
            l for l in tout.split("\n") if l.strip())[:300]
        return res

    zk, z_uncoded = keys_from(zout, tsgo=False)
    tk, _ = keys_from(tout, tsgo=True)
    excess = sorted(zk - tk)
    under = sorted(tk - zk)
    res["n_ztsc"] = len(zk)
    res["n_tsgo"] = len(tk)
    res["excess"] = excess
    res["under"] = under
    # tsc reports SYNTACTIC diagnostics alone: when its parser errors it never
    # runs the semantic pass. ztsc has no such gate — it reports the parse error
    # (uncoded, so invisible to the key extractor) and every semantic error
    # after it. The two diagnostic sets are then structurally incomparable, so
    # a case whose parse ztsc rejected is bucketed on its own rather than
    # counted as thousands of "false positives". Its keys are still listed.
    if z_uncoded:
        res["status"] = "parse_case"
        if not args.keep:
            shutil.rmtree(case_dir, ignore_errors=True)
        return res
    if not excess and not under:
        res["status"] = "match"
    elif excess and under:
        res["status"] = "mixed"
    elif excess:
        res["status"] = "excess_only"
    else:
        res["status"] = "under_only"
    if any(k.startswith("(config)") for k in tk):
        res["tsgo_config_error"] = True
    if not args.keep:
        shutil.rmtree(case_dir, ignore_errors=True)
    return res


# -------------------------------------------------------------------- report


def code_of(key: str) -> str:
    return key.rsplit(":", 1)[-1]


def write_report(args, results, elapsed):
    by_status = Counter(r["status"] for r in results)
    skips = Counter(r["category"] for r in results if r["status"] == "skip")
    skip_groups = Counter(r["category"].split(":")[0]
                          for r in results if r["status"] == "skip")
    notes = Counter(n for r in results for n in r.get("notes", ()))

    ran = [r for r in results if r["status"] in
           ("match", "mixed", "excess_only", "under_only")]
    diverging = [r for r in ran if r["status"] != "match"]
    excess_codes = Counter(code_of(k) for r in ran for k in r["excess"])
    under_codes = Counter(code_of(k) for r in ran for k in r["under"])
    both = Counter()
    for c, n in excess_codes.items():
        both[c] += n
    for c, n in under_codes.items():
        both[c] += n
    n_excess = sum(excess_codes.values())
    n_under = sum(under_codes.values())
    tsgo_cfg = [r for r in ran if r.get("tsgo_config_error")]

    L: list[str] = []
    A = L.append
    A("# ztsc vs tsgo — TypeScript suite divergence sweep")
    A("")
    A(f"- corpus: {args.corpus} @ `{args.commit}`")
    A(f"- oracle: `{args.tsgo}` ({args.tsgo_version})")
    A(f"- ztsc:   `{args.ztsc}` ({args.ztsc_build}), `--checkers=1 --workers=1`")
    A(f"- mode:   {'faithful pragmas' if args.faithful else 'normalized'} "
      f"(base options: {json.dumps(BASE_OPTIONS)})")
    A(f"- jobs:   {args.jobs}, per-tool timeout {args.timeout}s")
    A(f"- wall:   {elapsed / 60:.1f} min")
    A("")
    A("## Summary")
    A("")
    A(f"| metric | count |")
    A(f"|---|---:|")
    A(f"| cases discovered | {len(results)} |")
    A(f"| cases run | {len(ran)} |")
    A(f"| cases skipped | {by_status['skip']} |")
    A(f"| cases bucketed (ztsc parse error — tsc suppresses its semantic pass, "
      f"sets incomparable) | {by_status['parse_case']} |")
    A(f"| **matching exactly** | **{by_status['match']}** |")
    A(f"| diverging | {len(diverging)} |")
    A(f"| — ztsc-only errors (false positives) | {by_status['excess_only']} |")
    A(f"| — tsgo-only errors (under-report) | {by_status['under_only']} |")
    A(f"| — mixed | {by_status['mixed']} |")
    A(f"| excess error keys (ztsc reports, tsgo does not) | {n_excess} |")
    A(f"| missing error keys (tsgo reports, ztsc does not) | {n_under} |")
    A(f"| ztsc crashes | {by_status['ztsc_crash']} |")
    A(f"| ztsc timeouts (>{args.timeout}s) | {by_status['ztsc_timeout']} |")
    A(f"| tsgo crashes | {by_status['tsgo_crash']} |")
    A(f"| tsgo timeouts (>{args.timeout}s) | {by_status['tsgo_timeout']} |")
    A(f"| cases where the oracle raised a CONFIG error (harness smell) "
      f"| {len(tsgo_cfg)} |")
    if ran:
        A("")
        A(f"Match rate over run cases: "
          f"**{100.0 * by_status['match'] / len(ran):.1f}%**")
    A("")
    A("## Skips by category")
    A("")
    A("| category | cases |")
    A("|---|---:|")
    for cat, n in skip_groups.most_common():
        A(f"| {cat} | {n} |")
    A("")
    A("<details><summary>skips, fully qualified</summary>")
    A("")
    A("| category | cases |")
    A("|---|---:|")
    for cat, n in skips.most_common():
        A(f"| `{cat}` | {n} |")
    A("")
    A("</details>")
    A("")
    if notes:
        A("## Translation notes (case ran, pragma was rewritten)")
        A("")
        A("| note | cases |")
        A("|---|---:|")
        for n, c in notes.most_common():
            A(f"| `{n}` | {c} |")
        A("")
    A("## Top divergent error codes (the prioritization queue)")
    A("")
    A("| code | excess (ztsc-only) | missing (tsgo-only) | total |")
    A("|---|---:|---:|---:|")
    for code, tot in both.most_common(15):
        A(f"| {code} | {excess_codes[code]} | {under_codes[code]} | {tot} |")
    A("")
    A("### Top excess codes")
    A("")
    A("| code | keys | cases |")
    A("|---|---:|---:|")
    ecases = Counter()
    for r in ran:
        for c in {code_of(k) for k in r["excess"]}:
            ecases[c] += 1
    for code, n in excess_codes.most_common(15):
        A(f"| {code} | {n} | {ecases[code]} |")
    A("")
    A("### Top missing codes")
    A("")
    A("| code | keys | cases |")
    A("|---|---:|---:|")
    ucases = Counter()
    for r in ran:
        for c in {code_of(k) for k in r["under"]}:
            ucases[c] += 1
    for code, n in under_codes.most_common(15):
        A(f"| {code} | {n} | {ucases[code]} |")
    A("")
    if by_status["ztsc_crash"] or by_status["ztsc_timeout"]:
        A("## ztsc crashes / timeouts")
        A("")
        for r in results:
            if r["status"] in ("ztsc_crash", "ztsc_timeout"):
                A(f"- `{r['case']}` — {r['status']} {r.get('detail', '')}")
        A("")
    if by_status["tsgo_crash"] or by_status["tsgo_timeout"]:
        A("## tsgo crashes / timeouts")
        A("")
        for r in results:
            if r["status"] in ("tsgo_crash", "tsgo_timeout"):
                A(f"- `{r['case']}` — {r['status']} {r.get('detail', '')}")
        A("")
    parse_cases = [r for r in results if r["status"] == "parse_case"]
    if parse_cases:
        A("## Parse-error cases (bucketed, not scored)")
        A("")
        A("ztsc's parser rejected these, so tsc reported only its own syntactic "
          "diagnostics and never ran the semantic pass. Listed with their raw "
          "key deltas for triage; a case here with **no** tsgo syntactic "
          "diagnostic is a ztsc false parse error.")
        A("")
        for r in sorted(parse_cases, key=lambda r: r["case"]):
            A(f"- `{r['case']}` — ztsc {r['n_ztsc']} coded key(s) "
              f"(+{len(r['excess'])}), tsgo {r['n_tsgo']} (-{len(r['under'])})")
        A("")

    A("## Per-case divergences")
    A("")
    A("`+` = ztsc reports a key tsgo does not (false positive); "
      "`-` = tsgo reports a key ztsc does not (under-report).")
    A("")
    for r in sorted(diverging, key=lambda r: r["case"]):
        A(f"### `{r['case']}` ({r['status']}: "
          f"+{len(r['excess'])} / -{len(r['under'])})")
        for k in r["excess"]:
            A(f"    + {k}")
        for k in r["under"]:
            A(f"    - {k}")
        A("")

    os.makedirs(os.path.dirname(args.report), exist_ok=True)
    with open(args.report, "w") as f:
        f.write("\n".join(L) + "\n")

    tsv = os.path.splitext(args.report)[0] + ".tsv"
    with open(tsv, "w") as f:
        f.write("case\tstatus\tcategory\tn_ztsc\tn_tsgo\texcess\tunder\n")
        for r in sorted(results, key=lambda r: r["case"]):
            f.write("\t".join([
                r["case"], r["status"], r.get("category", ""),
                str(r.get("n_ztsc", "")), str(r.get("n_tsgo", "")),
                ",".join(r.get("excess", ())), ",".join(r.get("under", ())),
            ]) + "\n")
    return L, tsv


# ---------------------------------------------------------------------- main


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--corpus", default="bench/ts-suite/TypeScript")
    ap.add_argument("--work", default="bench/ts-suite/work")
    ap.add_argument("--report", default="bench/ts-suite/report.md")
    ap.add_argument("--ztsc", default="zig-out/bench/ztsc")
    ap.add_argument("--tsgo", required=True)
    ap.add_argument("--jobs", type=int, default=max(1, (os.cpu_count() or 4)))
    ap.add_argument("--timeout", type=float, default=10.0)
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--filter", default="")
    ap.add_argument("--faithful", action="store_true")
    ap.add_argument("--keep", action="store_true",
                    help="keep every materialized case dir (triage aid)")
    args = ap.parse_args()

    global LIB_SOURCE
    LIB_SOURCE = os.path.abspath(os.path.join(args.corpus, "tests/lib"))
    args.ztsc = os.path.abspath(args.ztsc)
    args.tsgo = os.path.abspath(args.tsgo)
    args.work = os.path.abspath(args.work)
    args.report = os.path.abspath(args.report)

    roots = [os.path.join(args.corpus, "tests/cases/compiler"),
             os.path.join(args.corpus, "tests/cases/conformance")]
    tests: list[tuple[str, str]] = []
    for root in roots:
        for dirpath, _, names in os.walk(root):
            for n in sorted(names):
                if not n.endswith((".ts", ".tsx")):
                    continue
                p = os.path.join(dirpath, n)
                rel = os.path.relpath(p, os.path.join(args.corpus, "tests/cases"))
                if args.filter and args.filter not in rel:
                    continue
                tests.append((p, rel))
    tests.sort(key=lambda t: t[1])
    if args.limit:
        tests = tests[:args.limit]

    args.commit = subprocess.run(
        ["git", "-C", args.corpus, "rev-parse", "HEAD"],
        capture_output=True, text=True).stdout.strip() or "unknown"
    args.tsgo_version = subprocess.run(
        [args.tsgo, "--version"], capture_output=True, text=True
    ).stdout.strip() or "unknown"
    args.ztsc_build = "ReleaseFast" if "/bench/" in args.ztsc else "debug"

    print(f"ts_suite: {len(tests)} case files, {args.jobs} jobs, "
          f"{args.timeout}s timeout, "
          f"{'faithful' if args.faithful else 'normalized'} mode")
    shutil.rmtree(args.work, ignore_errors=True)
    os.makedirs(args.work, exist_ok=True)

    t0 = time.time()
    results = []
    done = 0
    with ThreadPoolExecutor(max_workers=args.jobs) as ex:
        for r in ex.map(lambda t: run_case(args, t[0], t[1]), tests):
            results.append(r)
            done += 1
            if done % 250 == 0 or done == len(tests):
                el = time.time() - t0
                rate = done / el if el else 0
                print(f"  {done}/{len(tests)}  {el / 60:.1f}min  "
                      f"{rate:.1f}/s  eta {(len(tests) - done) / rate / 60:.1f}min"
                      if rate else f"  {done}/{len(tests)}", flush=True)
    elapsed = time.time() - t0

    body, tsv = write_report(args, results, elapsed)
    print()
    head = body.index("## Skips by category")
    print("\n".join(body[:head]))
    print(f"report: {args.report}")
    print(f"tsv:    {tsv}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
