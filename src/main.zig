//! ZTSC CLI: argument parsing, tsconfig loading, and the phase orchestration
//! around the two halves that do the work — `driver.build` (discovery,
//! front end, renumbering, link) and the check phase it schedules with
//! schedule.zig. What stays here is the process's own business: what the user
//! asked for, what the config says, what gets printed, and the exit code.
//!
//! The CLI-overrides-tsconfig precedence rules are settled in ONE place
//! (`effectiveOptions`) and handed to the driver as values; nothing below
//! re-reads the config.
//!
//! Output determinism: the file order is derived from the graph, never
//! from scheduling (driver.zig); every diagnostic is tagged with its file;
//! each file's check diagnostics come from exactly the checker that owns it,
//! and the final print is per file (in graph order), position-sorted —
//! byte-identical for any --workers/--checkers combination. `--timing`
//! reports the per-phase split (`config` is tsconfig loading and its
//! `include` walk; load/parse/bind are summed per-file worker times,
//! since files stream through the pipeline; `discover` is the front-end
//! wall clock) plus a per-checker breakdown; `--memory`
//! reports arena/token/AST/binder statistics plus per-checker type-store
//! bytes and module-graph bytes.

const std = @import("std");
const Io = std.Io;
const ztsc = @import("ztsc");
const Source = ztsc.source.Source;
const Interner = ztsc.intern.Interner;
const checker = ztsc.checker;
const libs = ztsc.libs;
const modules = ztsc.modules;
const resolve = ztsc.resolve;
const types = ztsc.types;
const driver = ztsc.driver;
const schedule = ztsc.schedule;
const Timer = driver.Timer;
const FileOrder = driver.FileOrder;

const usage =
    \\usage: ztsc [options] [files...]
    \\
    \\With no files, ztsc looks for tsconfig.json in the current directory
    \\and its parents (or uses --project). See the README for the checked
    \\TypeScript subset.
    \\
    \\options:
    \\  -p, --project <path>   use the tsconfig.json at <path> (file or dir)
    \\  --pretty[=true|false]  tsc-style colored diagnostics with source
    \\                         excerpts (default: on when stderr is a TTY)
    \\  --verbose              print notes about accepted-but-ignored
    \\                         tsconfig options
    \\  --timing               print per-phase wall-clock timings
    \\  --memory               print arena / memory statistics
    \\  --dump-ast             print S-expression parse trees (golden-test format)
    \\  --dump-symbols         print binder scope/symbol dumps (golden-test format)
    \\  --dump-types           print per-declaration checked types (golden-test format)
    \\  --noLib                skip the built-in ES-core lib (no globals,
    \\                         no primitive/array methods; matches tsc)
    \\  --lib=a,b,c            select built-in libs (es*, dom); overrides the
    \\                         tsconfig 'lib' field. Default: es-core + dom
    \\                         (matches tsgo's target-esnext default)
    \\  --skip-default-lib-check
    \\                         do NOT type-check the embedded lib files
    \\                         themselves (checked by default, matching tsc/
    \\                         tsgo; tsc's skipDefaultLibCheck). tsconfig
    \\                         skipDefaultLibCheck does the same; tsconfig
    \\                         skipLibCheck is the superset — it suppresses all
    \\                         diagnostics in every .d.ts (their types still flow)
    \\  --workers=N            number of worker threads (default: CPU count)
    \\  --checkers=N           number of checker instances (default:
    \\                         min(4, CPUs), or 2 on a small program —
    \\                         each instance costs fixed state that little
    \\                         checking does not repay)
    \\  --repeat=N             parse/bind each file N times (benchmark aid;
    \\                         does not cover the built-in lib, which is
    \\                         front-ended once before the pool starts)
    \\  --no-resolve-cache     disable the module-resolution memos — the
    \\                         specifier memo and the filesystem-fact caches
    \\                         under it (benchmark aid / correctness oracle)
    \\  --no-frozen-store      disable the shared frozen base type store; each
    \\                         checker re-expands lib types (benchmark aid / oracle)
    \\  --no-inst-cache        disable the instantiation caching layer; re-run
    \\                         every substitution (benchmark aid / oracle)
    \\  --census               tally out-of-subset constructs by frequency
    \\  --inst-profile         dump the instantiation-demand profile (where a
    \\                         statement's instantiation budget goes) to stderr;
    \\                         pair with --checkers=1
    \\  --inst-focus=ID        restrict that profile's per-type histogram to
    \\                         one substitution root (a #id from its report)
    \\  --decl-profile         dump the declaration-window TIME profile (what
    \\                         share of the check phase materializes
    \\                         declarations) to stderr; pair with --checkers=1
    \\  --mem-profile          dump each checker's per-container byte
    \\                         breakdown and footprint timeline to stderr
    \\  --inst-memo-bits=N     log2 of the per-checker instantiation memo's
    \\                         slot count (12 bytes a slot; measurement aid)
    \\  --dup-profile          implies --decl-profile and adds the raw
    \\                         (declaration unit, cost, demanding files) table
    \\                         the cross-checker duplication analysis reads;
    \\                         pair with --checkers=1
    \\  --file-order=ORDER     permute the root file list before seeding:
    \\                         source (default), reverse, or shuffle=SEED.
    \\                         The result must not change (correctness axis;
    \\                         see bench/order_sweep.sh)
    \\  --eager-members        materialize every interface/class member table
    \\                         whole, instead of member-by-member on demand
    \\                         (bisect leg / oracle)
    \\  --alias-refs           keep ref(alias, args) as the spelling for every
    \\                         generic alias instantiation, so alias identity
    \\                         survives structural interning (bisect leg)
    \\  --variance-decides     believe a complete measured-variance comparison
    \\                         in both directions, with no structural fallback
    \\                         (bisect leg)
    \\  -h, --help             print this help and exit
    \\  --version              print version and exit
    \\
    \\exit codes: 0 no errors; 1 type/syntax errors reported; 2 usage,
    \\config, or file-system errors.
    \\
;

const Cli = struct {
    timing: bool = false,
    memory: bool = false,
    dump_ast: bool = false,
    dump_symbols: bool = false,
    dump_types: bool = false,
    version: bool = false,
    help: bool = false,
    verbose: bool = false,
    /// Skip lib injection (globals/primitive methods); matches tsc --noLib.
    no_lib: bool = false,
    /// Opt out of type-checking the embedded lib files themselves. By default
    /// they are parsed/bound/linked (globals, lazy type expansion) AND walked
    /// by the checkers, matching tsc/tsgo, which check their default lib at
    /// their defaults. `--skip-default-lib-check` (or the tsconfig
    /// `skipLibCheck`/`skipDefaultLibCheck` keys) reverts to skipping them —
    /// the shipped lib is pre-verified, so skipping only saves time.
    /// Diagnostics are identical either way: lib-file diagnostics are never
    /// surfaced. null = not specified on the CLI (tsconfig value, else check).
    skip_default_lib_check: ?bool = null,
    /// `--lib=a,b,c`: override the built-in lib selection (else the tsconfig
    /// `lib` field, else the default ES-core + DOM). null = not specified.
    lib: ?[]const []const u8 = null,
    /// Disable the module-resolution memo — the "before" leg of the
    /// resolution-cache benchmark; resolution then re-walks node_modules per
    /// importer. Diagnostics are identical either way.
    no_resolve_cache: bool = false,
    /// Disable the shared frozen base type store — the "before" leg of
    /// the frozen-store benchmark and the correctness oracle: every checker
    /// falls back to expanding lib types into its own store. Diagnostics are
    /// byte-identical either way and across `--checkers=N`.
    no_frozen_store: bool = false,
    /// Disable the instantiation caching layer (memoized `instantiate`,
    /// map interning, constraint + type-node memos) — the correctness oracle
    /// and benchmark "before" leg. Diagnostics are byte-identical either way
    /// and across `--checkers=N`; the depth/count limits stay active.
    no_inst_cache: bool = false,
    /// Print a by-construct histogram of out-of-subset syntax (census) —
    /// the frequency table that prioritizes upcoming feature work.
    census: bool = false,
    /// Dump the instantiation-demand profile (`src/checker/prof.zig`) to
    /// stderr at the end of each checker: where a statement's instantiation
    /// budget goes, by call site / root type / type kind / expanded symbol.
    /// A diagnostic instrument; pair with `--checkers=1`.
    inst_profile: bool = false,
    /// `--inst-focus=<type-id>`: restrict the profile's per-type histogram to
    /// one top-level substitution root (see `checker.Options.profile_focus_root`). Implies
    /// `--inst-profile`.
    inst_focus: u32 = 0,
    /// `--eager-members`: materialize an interface/class reference's whole
    /// member table at every consumer, the way the checker did before the lazy
    /// member route landed (see `lazyTableOf`). A bisect leg — any diagnostic
    /// movement the route causes is visible as a key-set diff against this
    /// flag in the same binary.
    eager_members: bool = false,
    /// `--alias-refs`: keep `ref(alias, args)` as the spelling for every
    /// generic alias instantiation whose body is `originTaggable`, so alias
    /// identity survives structural interning (see
    /// `checker.Options.alias_refs`). A bisect leg.
    alias_refs: bool = false,
    /// `--variance-decides`: believe a complete measured-variance comparison in
    /// both directions (see `checker.Options.variance_decides`). A bisect leg.
    variance_decides: bool = false,
    /// `--lazy-stats`: dump the lazy relation route.s hit/bail tally to stderr
    /// at seal. A diagnostic instrument; pair with `--checkers=1`.
    lazy_stats: bool = false,
    /// `--decl-profile`: dump the declaration-window time split to stderr at
    /// seal (see the second half of `checker/prof.zig`). A diagnostic
    /// instrument; pair with `--checkers=1`.
    decl_profile: bool = false,
    /// `--mem-profile`: dump each checker instance's per-container capacity
    /// breakdown, its demand-zeroed arrays' resident share, and its footprint
    /// timeline to stderr at seal (see `checker/memprof.zig`).
    mem_profile: bool = false,
    /// `--inst-memo-bits=N`: override the instantiation memo's slot count
    /// (`checker/memo.zig`'s `default_bits`). 0 = leave the default alone. A
    /// measurement aid — the memo's size is the per-checker footprint's single
    /// largest tunable.
    inst_memo_bits: u6 = 0,
    /// `--dup-profile`: implies `--decl-profile` and additionally records,
    /// per memoizable declaration unit, the set of OWNED files that demand
    /// it — the input to the partition-quality question. Pair with
    /// `--checkers=1`; see the cross-checker duplication section of
    /// `checker/prof.zig`.
    dup_profile: bool = false,
    /// `--partition-file=<path>`: benchmark aid; override the file->checker
    /// partition with an externally computed one (see the read site).
    partition_file: ?[]const u8 = null,
    /// `--file-order=<source|reverse|shuffle=SEED>`: permute the program's
    /// ROOT file list before anything is seeded from it. A correctness axis,
    /// not a benchmark aid: tsc's result does not depend on the order the
    /// roots are listed in, so neither may ztsc's. Nothing else varies —
    /// same files, same options, same `--checkers`. See `bench/order_sweep.sh`
    /// and the read site near `entry_paths`.
    file_order: FileOrder = .{ .source = {} },
    /// null = auto (pretty iff stderr is a TTY).
    pretty: ?bool = null,
    project: ?[]const u8 = null,
    workers: ?usize = null,
    checkers: ?usize = null,
    repeat: usize = 1,
    paths: []const []const u8 = &.{},
};

/// The options the run actually uses: the tsconfig's answers with the CLI's
/// overrides already applied. Produced once, by `effectiveOptions`, so the
/// precedence rules live in one testable place instead of in fifteen
/// `var config_*` locals threaded through main().
///
/// The defaults below are the no-tsconfig defaults (a run driven by bare file
/// arguments), which are NOT all `false`: ztsc always resolves with the
/// bundler algorithm, and tsc's rule makes `allowSyntheticDefaultImports`
/// default to true under it.
const Effective = struct {
    // --- module resolution ---
    resolve_json: bool = false,
    base_url: ?[]const u8 = null,
    allow_js: bool = false,
    /// Both default ON — see `tsconfig.Config`; a config that turns exports
    /// off gets the pre-`exports` resolver.
    resolve_pkg_json_exports: bool = true,
    resolve_pkg_json_imports: bool = true,
    /// tsconfig `moduleSuffixes` — widens every candidate probe the resolver
    /// makes; carried on `ResolveOpts` like every other resolution input.
    module_suffixes: []const []const u8 = &.{},
    /// tsconfig `paths`.
    paths_map: ?ztsc.tsconfig.Paths = null,
    /// `<jsxImportSource>/jsx-runtime` under the automatic JSX runtime; null
    /// under the classic runtime (global `JSX` namespace only).
    jsx_runtime_module: ?[]const u8 = null,
    /// Root identifier of tsconfig `jsxFactory` (`MyLib` for
    /// `MyLib.createElement`); the container tsc reads the `JSX` namespace
    /// out of. Null when unset.
    jsx_factory_ns: ?[]const u8 = null,

    // --- link / program semantics ---
    allow_synthetic_default: bool = true,
    /// tsconfig esModuleInterop, in its own right (NOT the synthetic-default
    /// question above, which defaults ON under bundler while this defaults
    /// off). See `tsconfig.Config.es_module_interop`.
    es_module_interop: bool = false,
    no_implicit_any: bool = true,
    /// tsconfig noUncheckedSideEffectImports (default on, as tsgo 7.0.2 has it
    /// — see `tsconfig.Config`).
    no_unchecked_side_effect_imports: bool = true,
    /// tsconfig `types: [… "*" …]` — TS2580 instead of TS2591 (see LinkOpts).
    types_wildcard: bool = false,
    /// tsconfig experimentalDecorators (legacy decorator dialect; grammar +
    /// the decorator signature check both change).
    experimental_decorators: bool = false,

    // --- lib injection and diagnostic suppression ---
    /// Which built-in lib blobs to inject.
    lib_set: libs.LibSet = .default,
    /// Skip type-checking the embedded pre-verified lib?
    skip_default_lib_check: bool = false,
    /// Honor `skipLibCheck`, the superset: no diagnostic located in ANY
    /// `.d.ts` is surfaced.
    skip_all_dts_check: bool = false,

    fn resolveOpts(e: Effective) resolve.ResolveOpts {
        return .{
            .resolve_json = e.resolve_json,
            .base_url = e.base_url,
            .allow_js = e.allow_js,
            .resolve_pkg_json_exports = e.resolve_pkg_json_exports,
            .resolve_pkg_json_imports = e.resolve_pkg_json_imports,
            .module_suffixes = e.module_suffixes,
        };
    }

    fn linkOpts(e: Effective) modules.LinkOpts {
        return .{
            .allow_synthetic_default = e.allow_synthetic_default,
            .es_module_interop = e.es_module_interop,
            .no_implicit_any = e.no_implicit_any,
            .no_unchecked_side_effect_imports = e.no_unchecked_side_effect_imports,
            .types_wildcard = e.types_wildcard,
            .experimental_decorators = e.experimental_decorators,
            .jsx_factory_ns = e.jsx_factory_ns,
        };
    }
};

/// Settle every option the run needs from the CLI and the tsconfig (null when
/// the run is driven by bare file arguments). Pure — no I/O, no allocation —
/// so the precedence rules can be tested directly.
fn effectiveOptions(cli: Cli, cfg: ?ztsc.tsconfig.Config) Effective {
    var e: Effective = .{};
    if (cfg) |c| {
        e.resolve_json = c.resolve_json_module;
        e.base_url = c.base_url;
        e.allow_js = c.allow_js;
        e.resolve_pkg_json_exports = c.resolve_pkg_json_exports;
        e.resolve_pkg_json_imports = c.resolve_pkg_json_imports;
        e.module_suffixes = c.module_suffixes;
        e.paths_map = c.paths;
        e.jsx_runtime_module = c.jsx_runtime_module;
        e.jsx_factory_ns = c.jsx_factory_ns;
        e.allow_synthetic_default = c.allow_synthetic_default_imports;
        e.es_module_interop = c.es_module_interop;
        e.no_implicit_any = c.no_implicit_any;
        e.no_unchecked_side_effect_imports = c.no_unchecked_side_effect_imports;
        e.types_wildcard = c.types_wildcard;
        e.experimental_decorators = c.experimental_decorators;
        // tsconfig skipLibCheck/skipDefaultLibCheck.
        e.skip_default_lib_check = c.skip_lib_check;
        // skipLibCheck only (the superset: ALL `.d.ts`, not just the lib).
        // Those files are still parsed/bound/linked so their types flow into
        // `.ts`/`.tsx` checking. Only the tsconfig drives this; the
        // `--skip-default-lib-check` CLI flag stays default-lib-only (tsc's
        // `--skipDefaultLibCheck`).
        e.skip_all_dts_check = c.skip_all_lib_check;
    }

    // The CLI flag, when given, overrides the tsconfig
    // `skipLibCheck`/`skipDefaultLibCheck` value. Default is to check the lib
    // (matching tsc/tsgo).
    if (cli.skip_default_lib_check) |v| e.skip_default_lib_check = v;

    // Which built-in lib blobs to inject. Precedence: --noLib wins (nothing),
    // then an explicit --lib flag, then the tsconfig `lib` field, else the
    // default set (ES-core + DOM — tsgo's target-esnext default includes DOM).
    e.lib_set = if (cli.no_lib)
        .none
    else
        libs.resolveLibSet(cli.lib orelse if (cfg) |c| c.lib else null);

    return e;
}

/// Routes diagnostics to the plain machine format or the pretty renderer,
/// tracking totals for the tsc-style summary line.
const Emitter = struct {
    out: *Io.Writer,
    pretty: bool,
    total: usize = 0,
    files_with: usize = 0,
    cur_file_had: bool = false,
    first_path: []const u8 = "",
    first_line: u32 = 0,

    fn beginFile(e: *Emitter) void {
        e.cur_file_had = false;
    }

    fn emit(
        e: *Emitter,
        path: []const u8,
        src: *const Source,
        span: ztsc.source.Span,
        ts_code: u16,
        msg: []const u8,
    ) !void {
        const lc = src.lineCol(@min(span.start, @as(u32, @intCast(src.bytes.len))));
        if (e.total == 0) {
            e.first_path = path;
            e.first_line = lc.line + 1;
        }
        e.total += 1;
        if (!e.cur_file_had) {
            e.cur_file_had = true;
            e.files_with += 1;
        }
        if (e.pretty) {
            try ztsc.render.renderPretty(e.out, true, path, src.bytes, src.line_starts, span, ts_code, msg);
        } else if (ts_code != 0) {
            try e.out.print("{s}:{d}:{d}: error TS{d}: {s}\n", .{ path, lc.line + 1, lc.col + 1, ts_code, msg });
        } else {
            try e.out.print("{s}:{d}:{d}: error: {s}\n", .{ path, lc.line + 1, lc.col + 1, msg });
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const gpa = init.gpa;
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_writer.interface;

    const args = try init.minimal.args.toSlice(arena);
    const cli = switch (try parseArgs(arena, args)) {
        .ok => |c| c,
        .bad => |b| {
            switch (b.problem) {
                .unknown_flag => std.debug.print("ztsc: unknown option '{s}'\n", .{b.arg}),
                .bad_value => std.debug.print("ztsc: bad value for option '{s}'\n", .{b.arg}),
                .missing_value => std.debug.print("ztsc: option '{s}' needs a value\n", .{b.arg}),
            }
            std.debug.print("try 'ztsc --help'\n", .{});
            std.process.exit(2);
        },
    };

    // This run's checker options: built once here, then copied by value into
    // every checker instance (see `checker.Options`). Instruments and bisect
    // legs only — nothing here changes an un-flagged run.
    const check_opts: checker.Options = .{
        .profile = cli.inst_profile,
        .profile_focus_root = cli.inst_focus,
        .decl_prof = cli.decl_profile or cli.dup_profile,
        .dup_prof = cli.dup_profile,
        .lazy_members = !cli.eager_members,
        .alias_refs = cli.alias_refs,
        .variance_decides = cli.variance_decides,
        .lazy_stats = cli.lazy_stats,
        .mem_prof = cli.mem_profile,
        .inst_memo_bits = cli.inst_memo_bits,
    };

    if (cli.help) {
        try out.print("{s}", .{usage});
        try out.flush();
        return;
    }
    if (cli.version) {
        try out.print("ztsc {s}\n", .{ztsc.version});
        try out.flush();
        return;
    }
    if (cli.paths.len != 0 and cli.project != null) {
        std.debug.print("ztsc: option '--project' cannot be mixed with source files on the command line\n", .{});
        std.process.exit(2);
    }

    // Everything from here on is real work, so `total` starts here rather than
    // after config loading: reading and expanding a tsconfig walks the project
    // tree, which on a large repo costs more than any single later phase and
    // must not hide outside the measured window.
    const total_timer = Timer.start(io);

    // With no file arguments, drive the run from a tsconfig.json.
    var entry_paths = cli.paths;
    // How many of `entry_paths` are REAL roots; the rest are the auto-included
    // `@types/*` ambient roots, which are ordered as a second wave (see the
    // renumbering block). Every root is real when the run is driven by CLI
    // file arguments.
    var n_real_roots = entry_paths.len;
    // The `config` phase: discovery, `extends` chasing, the `include` walk and
    // `collectAutoTypes`. Stays 0 when the run is driven by CLI file arguments.
    var config_ns: u64 = 0;
    // The loaded tsconfig, or null when the run is driven by CLI file
    // arguments. Read exactly once, by `effectiveOptions` below.
    var config: ?ztsc.tsconfig.Config = null;
    if (cli.paths.len == 0) {
        const config_timer = Timer.start(io);
        const config_path: []const u8 = blk: {
            if (cli.project) |p| {
                // Accept either the config file or its directory.
                if (Io.Dir.cwd().openDir(io, p, .{})) |d| {
                    var dir = d;
                    dir.close(io);
                    const trimmed = std.mem.trimEnd(u8, p, "/");
                    break :blk try std.fmt.allocPrint(arena, "{s}/tsconfig.json", .{trimmed});
                } else |_| {
                    break :blk p;
                }
            }
            break :blk (try ztsc.tsconfig.findUpward(io, arena)) orelse {
                std.debug.print("ztsc: no input files and no tsconfig.json found\ntry 'ztsc --help'\n", .{});
                std.process.exit(2);
            };
        };
        const cfg = ztsc.tsconfig.load(io, arena, config_path) catch |err| {
            switch (err) {
                error.NotFound => std.debug.print("ztsc: cannot read '{s}'\n", .{config_path}),
                error.SyntaxError => std.debug.print("ztsc: '{s}' is not valid JSON\n", .{config_path}),
                error.StrictFalse => std.debug.print(
                    "ztsc: '{s}' sets \"strict\": false, but ztsc only implements strict-mode semantics.\n" ++
                        "Please remove the option (or set it to true) to check this project with ztsc.\n",
                    .{config_path},
                ),
                error.OutOfMemory => return error.OutOfMemory,
            }
            std.process.exit(2);
        };
        for (cfg.warnings) |w| std.debug.print("ztsc: warning: {s}\n", .{w});
        if (cli.verbose) {
            for (cfg.notes) |n| std.debug.print("ztsc: note: {s}\n", .{n});
        }
        if (cfg.root_files.len == 0) {
            std.debug.print("ztsc: no inputs were found in config file '{s}'\n", .{config_path});
            std.process.exit(2);
        }
        // Real sources first (their order/emptiness drove the check above), then
        // the auto-included `@types/*` ambient roots (tsc's default typeRoots).
        // `n_real_roots` splits the two: the `@types/*` roots are seeded for
        // DISCOVERY here (so the wavefront still front-ends them in parallel)
        // but ORDERED as a second BFS wave, after the real roots' import
        // closure is exhausted — literally `createProgram`'s order, which walks
        // each root file with its whole closure and only then processes the
        // automatic type-reference directives.
        //
        // File order is merge order for a `declare global` augmentation, and
        // merge order decides which declaration group of a merged global
        // function comes LAST. social-app declares `setTimeout` in lib.dom,
        // in @types/node and in react-native's `globals.d.ts`; with the
        // `@types/*` roots ordered between the roots and their closure, node
        // landed BEFORE react-native and every `ReturnType<typeof setTimeout>`
        // came back `number` where tsc says `Timeout`.
        //
        // Deferring them was tried once before on its own and was worse: it
        // fixed `ReturnType` and broke the CALL, because overload resolution
        // used to read the merged list as one rotation of a lib/non-lib split
        // rather than group-by-group from the end. With
        // `mergedFunctionValue`/`appendOverloadCandidates` visiting declaration
        // groups back-to-front, both paths read the same last group and the
        // two halves of the answer finally agree.
        if (cfg.auto_type_files.len == 0) {
            entry_paths = cfg.root_files;
        } else {
            const combined = try arena.alloc([]const u8, cfg.root_files.len + cfg.auto_type_files.len);
            @memcpy(combined[0..cfg.root_files.len], cfg.root_files);
            @memcpy(combined[cfg.root_files.len..], cfg.auto_type_files);
            entry_paths = combined;
        }
        n_real_roots = cfg.root_files.len;
        config = cfg;
        config_ns = config_timer.readNs();
    }

    const opt = effectiveOptions(cli, config);

    // Pretty diagnostics: tsc-style excerpts + colors; default follows the
    // terminal, --pretty / --pretty=false forces.
    const pretty = cli.pretty orelse (Io.File.stderr().isTty(io) catch false);

    var interner = Interner.init();
    defer interner.deinit(gpa);

    // Not capped by the entry count: discovery finds more files.
    const cpu_count = std.Thread.getCpuCount() catch 1;
    const n_workers: usize = @max(1, cli.workers orelse cpu_count);

    // --- Front end: discover, parse, bind, renumber, link ------------------
    var dr = try driver.build(arena, gpa, io, &interner, .{
        .entry_paths = entry_paths,
        .n_real_roots = n_real_roots,
        .file_order = cli.file_order,
        .lib_set = opt.lib_set,
        .n_workers = n_workers,
        .repeat = cli.repeat,
        .resolve_cache = !cli.no_resolve_cache,
        .resolve_opts = opt.resolveOpts(),
        .paths_map = opt.paths_map,
        .jsx_runtime_module = opt.jsx_runtime_module,
        .link_opts = opt.linkOpts(),
    });
    // The lib shards' arenas hold AST and binder output the checkers read, so
    // they are released only at the very end of the run.
    defer dr.lib_fe.deinit();
    const prog = dr.prog;
    const links = prog.links;
    const paths = dr.files.paths;
    const results = dr.files.results;
    const trees = dr.files.trees;
    const binds = dr.files.binds;
    const errs = dr.files.errs;
    const workers = dr.workers;
    const n_files = paths.items.len;
    const n_entries = dr.n_entries;

    // --- Check (N independent checker instances) --------------------------------
    const check_timer = Timer.start(io);
    // File id -> owning checker, so per-file diagnostics can be reassembled
    // from the right checker below (replaces the old `i % n_checkers`).
    const file_owner = try arena.alloc(u32, n_files);

    // Cost-based partition, weighted by per-file AST node count
    // (≈ check cost, known post-parse) — see `schedule.partition` for how the
    // weights are spent. Built before the checker count is chosen, because
    // the total is what chooses it. Both per-file inputs are decided here
    // because only main knows the effective options; the model itself is
    // pure (schedule.zig).
    const node_counts = try arena.alloc(u64, n_files);
    const skipped = try arena.alloc(bool, n_files);
    for (0..n_files) |i| {
        node_counts[i] = if (trees.items[i]) |tree| tree.nodes.len else 0;
        // Embedded lib files are parsed/bound/linked (globals, lazy type
        // expansion) and, by default, also enqueued to a checker so the
        // pre-verified lib is walked just like tsc/tsgo at their defaults.
        // `--skip-default-lib-check` (or tsconfig skipLibCheck/
        // skipDefaultLibCheck) drops them — pure time savings, since lib
        // diagnostics are never surfaced (tsc's skipDefaultLibCheck).
        //
        // skipLibCheck: a non-lib `.d.ts` produces no surfaced check
        // diagnostics, and its types are resolved lazily on demand from
        // `.ts` files (not by walking it), so its check pass is dead work —
        // don't enqueue it. Pure time savings, deterministic (path-based).
        skipped[i] = (opt.skip_default_lib_check and libs.isLibPath(paths.items[i])) or
            (opt.skip_all_dts_check and ztsc.paths.isDeclarationPath(paths.items[i]));
    }
    const check_work = try schedule.costModel(arena, node_counts, skipped);

    const n_checkers: usize = @max(1, @min(schedule.defaultCheckers(cli.checkers, cpu_count, check_work.check_nodes, check_work.parsed_nodes), n_files));
    const tasks = try arena.alloc(schedule.CheckerTask, n_checkers);
    {
        // BENCHMARK AID (`--partition-file=<path>`): the partition can be
        // replaced with an externally computed one — one `<file-id> <checker>`
        // pair per line. Reading it is main's job; interpreting it is
        // `schedule.partition`'s.
        const partition_text: ?[]const u8 = if (cli.partition_file) |pf|
            Io.Dir.cwd().readFileAlloc(io, pf, arena, .limited(64 << 20)) catch |e| {
                std.debug.print("ztsc: cannot read --partition-file '{s}': {s}\n", .{ pf, @errorName(e) });
                std.process.exit(1);
            }
        else
            null;
        const owned = try schedule.partition(arena, check_work.items, n_checkers, file_owner, partition_text);

        // Shared frozen base type store (frozen-base piece 2): built
        // once, single-threaded here before any checker spawns, then handed to
        // every task read-only. Under `--no-frozen-store` each checker instead
        // expands lib types into its own store (the old path / oracle leg).
        // Lives in the top-level `arena` so it outlives all overlays.
        const base_store: ?*const types.Store = if (cli.no_frozen_store) null else blk: {
            const bs = try arena.create(types.Store);
            bs.* = try checker.buildBaseStore(arena);
            break :blk bs;
        };
        for (tasks, 0..) |*t, k| {
            t.* = .{
                .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
                .owned = owned[k],
                .base = base_store,
                .inst_cache = !cli.no_inst_cache,
                .opts = check_opts,
                // Only when the surface is not divisible. On a program whose
                // work DOES partition (the `multi` corpus, ratio 1.00), the
                // whole-program estimate over-reserves ~4x and costs peak RSS
                // for nothing: 41.2 -> 45.0 MiB measured.
                .type_reserve_hint = if (schedule.declarationHeavy(check_work.check_nodes, check_work.parsed_nodes))
                    @intCast(check_work.parsed_nodes)
                else
                    0,
            };
        }
    }
    if (n_checkers == 1) {
        tasks[0].run(io, gpa, &interner, prog);
    } else {
        for (tasks) |*t| {
            t.thread = try std.Thread.spawn(.{}, schedule.CheckerTask.run, .{ t, io, gpa, &interner, prog });
        }
        for (tasks) |*t| t.thread.join();
    }
    const check_ns = check_timer.readNs();

    // --- Aggregate statistics ----------------------------------------------
    var files_ok: usize = 0;
    var total_bytes: usize = 0;
    var total_lines: usize = 0;
    var line_table_bytes: usize = 0;
    for (results.items) |maybe_src| {
        const src = maybe_src orelse continue;
        files_ok += 1;
        total_bytes += src.bytes.len;
        total_lines += src.lineCount();
        line_table_bytes += src.lineTableBytes();
    }

    // Token stats come from the retained `tree.tokens` (the only token
    // array the front end builds per file).
    var total_tokens: usize = 0;
    var token_bytes: usize = 0;
    var total_nodes: usize = 0;
    var node_bytes: usize = 0;
    var extra_bytes: usize = 0;
    var ast_token_bytes: usize = 0;
    // The injected libs' own diagnostics are never reported (the print
    // loop below skips them, matching tsc, which does not diagnose the
    // default lib), so they must not count toward the summary line or
    // the exit code either — otherwise a clean project exits 1 with
    // nothing printed. There may be several lib files (ES-core, DOM, the
    // console shim); `is_lib[i]` flags each by its synthetic path.
    const is_lib = try arena.alloc(bool, paths.items.len);
    for (paths.items, 0..) |p, i| is_lib[i] = libs.isLibPath(p);

    // Non-lib `.d.ts` files whose diagnostics are fully suppressed by
    // `skipLibCheck` (parse + bind + link + check), mirroring how the built-in
    // lib is suppressed. See the emit loop for why parser diagnostics are
    // dropped too (ztsc can't distinguish a genuine syntax error from a
    // parser-subset-gap cascade, and valid published `.d.ts` have neither).
    // Path-based, so identical for any --workers/--checkers count (determinism).
    const dts_skipped = try arena.alloc(bool, paths.items.len);
    for (paths.items, 0..) |p, i|
        dts_skipped[i] = opt.skip_all_dts_check and !is_lib[i] and ztsc.paths.isDeclarationPath(p);

    // `@ts-nocheck` / `@ts-ignore` / `@ts-expect-error` suppression, scanned
    // from each file's comment trivia at parse time. Unlike `dts_skipped` this
    // only covers *semantic* diagnostics (bind + link + check); syntax errors
    // still report, as in tsc. Content-derived, so identical for any
    // --workers/--checkers count.
    const cdirs = try arena.alloc(ztsc.directives.File, paths.items.len);
    for (trees.items, 0..) |maybe_tree, i|
        cdirs[i] = if (maybe_tree) |tree| tree.comment_directives else .none;

    // THE SYNTACTIC GATE. tsc reports the whole program's syntactic
    // diagnostics and, if there is even one, never runs the semantic pass:
    //
    //     addRange(allDiagnostics, program.getSyntacticDiagnostics(...));
    //     if (allDiagnostics.length === configFileParsingDiagnosticsLength) {
    //         ... getOptionsDiagnostics / getGlobalDiagnostics ...
    //         if (allDiagnostics.length === configFileParsingDiagnosticsLength)
    //             ... getSemanticDiagnostics ...
    //     }
    //
    // It is PROGRAM-wide, not per-file — verified against tsgo 7.0.2 with a
    // two-file project (a parse error in `a.ts` suppressed a TS2322 in `b.ts`).
    // The reason is sound rather than incidental: a file the parser could not
    // read produces a tree the binder and checker then reason about wrongly, and
    // its exports are wrong for every importer, so the whole program's semantic
    // answers are suspect.
    //
    // Scope: only diagnostics whose class is `.syntactic` arm the gate, and only
    // from files ztsc actually reports on. `.grammar` diagnostics carry TS1xxx
    // codes but come from tsc's grammar-check pass, which is semantic — they are
    // gated, not gating. `.subset` (ztsc's "not supported yet") never gates: tsc
    // parses that construct happily, so there is no gate of tsc's to mirror and
    // arming one would silently stop checking a project over a missing feature.
    // Lib and `skipLibCheck`-suppressed `.d.ts` files are excluded for the same
    // reason their diagnostics are: a parser-subset gap there is not evidence
    // about the user's code.
    var parse_diags: usize = 0;
    var syntactic_error = false;
    for (trees.items, 0..) |maybe_tree, i| {
        const tree = maybe_tree orelse continue;
        total_tokens += tree.tokens.len();
        token_bytes += tree.tokens.byteSize();
        total_nodes += tree.nodes.len;
        node_bytes += tree.nodeBytes();
        extra_bytes += tree.extraBytes();
        ast_token_bytes += tree.tokens.byteSize();
        if (is_lib[i] or dts_skipped[i]) continue;
        for (tree.diagnostics) |d| {
            switch (d.code.class()) {
                .syntactic => {
                    syntactic_error = true;
                    parse_diags += 1;
                },
                .subset => parse_diags += 1,
                .grammar => {},
            }
        }
    }
    // A grammar diagnostic is semantic, so it is only counted (and only
    // reported) when the gate is open. Second pass because the gate is not known
    // until every file has been seen.
    if (!syntactic_error) {
        for (trees.items, 0..) |maybe_tree, i| {
            const tree = maybe_tree orelse continue;
            if (is_lib[i] or dts_skipped[i]) continue;
            for (tree.diagnostics) |d| {
                if (d.code.class() != .grammar) continue;
                if (!cdirs[i].suppresses(d.span.start)) parse_diags += 1;
            }
        }
    }

    var total_symbols: usize = 0;
    var total_scopes: usize = 0;
    var total_flows: usize = 0;
    var bind_symbol_bytes: usize = 0;
    var bind_scope_bytes: usize = 0;
    var bind_flow_bytes: usize = 0;
    var bind_record_bytes: usize = 0;
    var bind_diags: usize = 0;
    for (binds.items, 0..) |maybe_bind, i| {
        const b = maybe_bind orelse continue;
        total_symbols += b.symbolCount();
        total_scopes += b.scopeCount();
        total_flows += b.flowCount();
        bind_symbol_bytes += b.symbolBytes();
        bind_scope_bytes += b.scopeBytes();
        bind_flow_bytes += b.flowBytes();
        bind_record_bytes += b.recordBytes();
        if (is_lib[i] or dts_skipped[i] or syntactic_error) continue;
        for (b.diagnostics) |d| {
            if (!cdirs[i].suppresses(d.span.start)) bind_diags += 1;
        }
    }

    var link_diags: usize = 0;
    for (links, 0..) |*l, i| {
        if (is_lib[i] or dts_skipped[i] or syntactic_error) continue;
        for (l.diags) |d| {
            if (!cdirs[i].suppresses(d.span.start)) link_diags += 1;
        }
    }

    var check_diags: usize = 0;
    var check_types: usize = 0;
    var check_type_bytes: usize = 0;
    var check_rel_entries: usize = 0;
    var check_rel_bytes: usize = 0;
    var check_rel_hits: usize = 0;
    var check_rel_misses: usize = 0;
    var check_nt_hits: usize = 0;
    var check_nt_misses: usize = 0;
    var check_scratch_hw: usize = 0;
    var check_flow_queries: usize = 0;
    var check_inst_hits: usize = 0;
    var check_inst_misses: usize = 0;
    var check_inst_maps: usize = 0;
    var check_instantiations: usize = 0;
    for (tasks) |*t| {
        const ck = t.result orelse continue;
        for (ck.diagnostics) |d| {
            if (syntactic_error) break;
            if (is_lib[d.file] or dts_skipped[d.file]) continue;
            if (cdirs[d.file].suppresses(d.span.start)) continue;
            check_diags += 1;
        }
        check_types += ck.stats.types_created;
        check_type_bytes += ck.stats.type_bytes;
        check_rel_entries += ck.stats.relation_entries;
        check_rel_bytes += ck.stats.relation_bytes;
        check_rel_hits += ck.stats.relation_hits;
        check_rel_misses += ck.stats.relation_misses;
        check_nt_hits += ck.stats.node_type_hits;
        check_nt_misses += ck.stats.node_type_misses;
        if (ck.stats.scratch_high_water > check_scratch_hw) check_scratch_hw = ck.stats.scratch_high_water;
        check_flow_queries += ck.stats.flow_queries;
        check_inst_hits += ck.stats.inst_hits;
        check_inst_misses += ck.stats.inst_misses;
        check_inst_maps += ck.stats.inst_maps;
        check_instantiations += ck.stats.instantiations;
    }

    var failed: usize = 0;
    for (errs.items, paths.items) |maybe_err, path| {
        if (maybe_err) |err| {
            failed += 1;
            std.debug.print("ztsc: {s}: {s}\n", .{ path, @errorName(err) });
        }
    }
    for (tasks) |*t| {
        if (t.err) |err| {
            failed += 1;
            std.debug.print("ztsc: checker: {s}\n", .{@errorName(err)});
        }
    }

    const total_ns = total_timer.readNs();

    // --- Diagnostics: per file (discovery order), position-sorted ----------
    // Parse diagnostics first (message-only), then bind + link + check
    // merged by (position, code). Byte-identical for any --checkers=N.
    // Non-pretty output is the stable machine format; --pretty renders
    // tsc-style excerpts plus the final summary line.
    const cursors = try arena.alloc(usize, n_checkers);
    @memset(cursors, 0);

    var emitter: Emitter = .{ .out = out, .pretty = pretty };

    // THE OPTIONS GATE. tsc runs `getOptionsDiagnostics` between the syntactic
    // and the semantic pass, and each pass only runs when the one before it
    // added nothing (see the pseudo-code at the syntactic gate above, and
    // `tsconfig.ConfigDiag`). So a config error — currently TS5102 for an
    // option TypeScript 7 removed — is reported only when the program parses
    // clean, and when it is reported it is the ONLY thing reported: every
    // bind/link/check diagnostic in the program is suppressed, because the
    // options the checker would have run under are not the ones the user
    // asked for. Verified against tsgo 7.0.2.
    const config_diags: []const ztsc.tsconfig.ConfigDiag =
        if (syntactic_error) &.{} else if (config) |c| c.config_diags else &.{};
    if (config_diags.len != 0) {
        const cfg = config.?;
        var config_src = try Source.fromBytes(arena, cfg.path, cfg.text);
        emitter.beginFile();
        for (config_diags) |d|
            try emitter.emit(cfg.path, &config_src, .{ .start = d.start, .end = d.end }, d.code, d.msg);
        // Suppressed, so not reported and not counted (they drive the exit
        // code and the `--stats` line alike).
        parse_diags = 0;
        bind_diags = 0;
        link_diags = 0;
        check_diags = 0;
    }

    const Merged = struct {
        code: u16,
        start: u32,
        end: u32,
        msg: []const u8,
    };
    // Zero under the options gate: the per-file loop below is what tsc's
    // suppressed semantic pass would have produced.
    const n_emit_files: usize = if (config_diags.len != 0) 0 else n_files;
    for (0..n_emit_files) |i| {
        const path = paths.items[i];
        const src = results.items[i] orelse continue;
        const tree = trees.items[i] orelse continue;
        // Never surface diagnostics from the built-in lib itself, matching
        // tsc, which does not diagnose the default lib. The vendored real
        // 7.0.2 lib is census-clean but trips a few ztsc-incompleteness
        // diagnostics (`intrinsic`, `globalThis`, merged-interface duplicate
        // members); those degrade the affected lib types to `any` rather than
        // leaking spurious errors onto every user run. Diagnostic cursor for
        // the lib's owning checker is still advanced below so later files stay
        // aligned. Libs are the first files 0.. (see the injection site).
        //
        // Under `skipLibCheck`, `dts_skipped[i]` extends the same full
        // suppression to every non-lib `.d.ts`. tsc keeps *syntactic* errors in
        // `.d.ts` but suppresses semantic ones; ztsc cannot tell a genuine
        // syntax error from a parser-subset-gap cascade (both are parser
        // diagnostics), and real published `.d.ts` are syntactically valid, so
        // any parser diagnostic there is overwhelmingly a ztsc false positive.
        // The no-false-positives constraint + the under-report policy make
        // suppressing the whole file the correct call: zero surfaced `.d.ts`
        // diagnostics, matching tsc's observable output on valid `.d.ts`. Their
        // types still flow into `.ts` checking (they are parsed/bound/linked).
        if (is_lib[i] or dts_skipped[i]) {
            const owner = file_owner[i];
            if (tasks[owner].result) |ck| {
                var cur = cursors[owner];
                while (cur < ck.diagnostics.len and ck.diagnostics[cur].file == i) : (cur += 1) {}
                cursors[owner] = cur;
            }
            continue;
        }
        emitter.beginFile();

        var merged: std.ArrayList(Merged) = .empty;
        defer merged.deinit(gpa);
        // Parser diagnostics: those with a tsc analogue (e.g. TS1206) render
        // with their code and sort into the merged stream; the rest keep their
        // own messages.
        const cd = cdirs[i];
        for (tree.diagnostics) |d| {
            // A grammar diagnostic (TS1274, TS1206, TS5076, ...) is one of
            // tsc's SEMANTIC diagnostics despite its TS1xxx number, so the
            // syntactic gate and the comment directives both apply to it.
            if (d.code.class() == .grammar) {
                if (syntactic_error) continue;
                if (cd.suppresses(d.span.start)) continue;
            }
            const ts = d.code.tsCode();
            // A message that interpolates a name (the JSX unclosed-tag family)
            // is rendered HERE, where the file's source buffer is in hand; the
            // result lives in the program arena, which outlives the emit below.
            const msg = try ztsc.diagnostics.renderMessage(arena, d, src.bytes);
            if (ts != 0) {
                try merged.append(gpa, .{ .code = ts, .start = d.span.start, .end = d.span.end, .msg = msg });
            } else {
                try emitter.emit(path, &src, d.span, 0, msg);
            }
        }
        // Bind, link and check diagnostics are *semantic*, so a `@ts-nocheck`
        // file pragma or a preceding `@ts-ignore`/`@ts-expect-error` drops
        // them (tsc excludes exactly these three from a `@ts-nocheck` file and
        // filters the same set through the comment-directive map), and so does
        // a syntactic error anywhere in the program (see the gate above).
        // Syntactic parser diagnostics survive both.
        if (binds.items[i]) |b| {
            for (b.diagnostics) |d| {
                if (syntactic_error) break;
                if (cd.suppresses(d.span.start)) continue;
                const ts = d.code.tsCode();
                const msg = try ztsc.diagnostics.renderMessage(arena, d, src.bytes);
                if (ts != 0) {
                    try merged.append(gpa, .{ .code = ts, .start = d.span.start, .end = d.span.end, .msg = msg });
                } else {
                    try emitter.emit(path, &src, d.span, 0, msg);
                }
            }
        }
        if (!syntactic_error) {
            for (links[i].diags) |d| {
                if (cd.suppresses(d.span.start)) continue;
                try merged.append(gpa, .{ .code = d.code, .start = d.span.start, .end = d.span.end, .msg = d.msg });
            }
        }
        // The owning checker's cursor is advanced past this file either way, so
        // later files stay aligned with their own diagnostics under the gate.
        const owner = file_owner[i];
        if (tasks[owner].result) |ck| {
            var cur = cursors[owner];
            while (cur < ck.diagnostics.len and ck.diagnostics[cur].file == i) : (cur += 1) {
                if (syntactic_error) continue;
                const d = ck.diagnostics[cur];
                if (cd.suppresses(d.span.start)) continue;
                try merged.append(gpa, .{ .code = d.code, .start = d.span.start, .end = d.span.end, .msg = d.msg });
            }
            cursors[owner] = cur;
        }
        std.mem.sort(Merged, merged.items, {}, struct {
            fn lessThan(_: void, x: Merged, y: Merged) bool {
                if (x.start != y.start) return x.start < y.start;
                return x.code < y.code;
            }
        }.lessThan);
        // tsc's `sortAndDeduplicateDiagnostics`: two diagnostics identical in
        // position, code and text are one diagnostic. A recovering parser
        // reaches the same dead end from two nesting levels (`<div><span>` at
        // end of file wants "'</' expected" for each), and the
        // one-per-position rule only compares against the LAST diagnostic, so
        // it cannot catch the pair when a third lands between them. The list
        // is already sorted by position, so the duplicates are adjacent.
        var prev: ?Merged = null;
        for (merged.items) |d| {
            if (prev) |q| {
                if (q.start == d.start and q.end == d.end and q.code == d.code and
                    std.mem.eql(u8, q.msg, d.msg)) continue;
            }
            prev = d;
            try emitter.emit(path, &src, .{ .start = d.start, .end = d.end }, d.code, d.msg);
        }
    }
    if (pretty) {
        try ztsc.render.renderSummary(out, true, emitter.total, emitter.files_with, emitter.first_path, emitter.first_line);
    }

    // --- AST dump (--dump-ast) ---------------------------------------------
    if (cli.dump_ast) {
        for (trees.items, results.items, paths.items) |maybe_tree, maybe_src, path| {
            const tree = maybe_tree orelse continue;
            const src = maybe_src orelse continue;
            try out.print(";; {s}\n", .{path});
            var it = tree.childIterator(0);
            while (it.next()) |child| {
                try tree.dump(src.bytes, out, child);
                try out.writeAll("\n");
            }
        }
    }

    // --- Symbol dump (--dump-symbols) ---------------------------------------
    if (cli.dump_symbols) {
        for (binds.items, trees.items, results.items, paths.items) |maybe_bind, maybe_tree, maybe_src, path| {
            const b = maybe_bind orelse continue;
            const tree = maybe_tree orelse continue;
            const src = maybe_src orelse continue;
            try out.print(";; {s}\n", .{path});
            try b.dump(io, &interner, tree, src.bytes, out);
        }
    }

    if (cli.dump_types) {
        var dump_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer dump_arena.deinit();
        const all_files = try dump_arena.allocator().alloc(modules.FileId, n_files);
        for (all_files, 0..) |*f, i| f.* = @intCast(i);
        _ = checker.checkFilesAndDump(dump_arena.allocator(), io, gpa, &interner, prog, all_files, null, true, 0, check_opts, out) catch {};
    }

    try out.print("ztsc: loaded {d} file(s) ({d} from CLI), {d} lines, {d} bytes, {d} tokens, {d} nodes, {d} symbols, {d} parse error(s), {d} bind error(s), {d} link error(s), {d} check error(s) ({d} worker(s), {d} checker(s))\n", .{
        files_ok,    n_entries,  total_lines, total_bytes, total_tokens, total_nodes, total_symbols,
        parse_diags, bind_diags, link_diags,  check_diags, n_workers,    n_checkers,
    });

    if (cli.census) {
        try ztsc.report.printCensus(out, trees.items, .{
            .files = n_files,
            .lines = total_lines,
            .parse_diags = parse_diags,
            .bind_diags = bind_diags,
            .check_diags = check_diags,
        });
    }

    if (cli.timing) {
        const checker_times = try arena.alloc(ztsc.report.CheckerTime, tasks.len);
        for (tasks, checker_times) |*t, *ct| ct.* = .{ .ns = t.ns, .files = t.owned.len };
        const rcache = dr.rcache;
        const fs_counts = rcache.fs.entryCounts();
        try ztsc.report.printTiming(out, .{
            .config_ns = config_ns,
            .load_ns = dr.timings.load_ns,
            .parse_ns = dr.timings.parse_ns,
            .bind_ns = dr.timings.bind_ns,
            .resolve_ns = dr.timings.resolve_ns,
            .discover_ns = dr.timings.discover_ns,
            .renumber_ns = dr.timings.renumber_ns,
            .link_ns = dr.timings.link_ns,
            .check_ns = check_ns,
            .total_ns = total_ns,
        }, .{
            .lines = total_lines,
            .bytes = total_bytes,
            .repeat = cli.repeat,
            .check_nodes = check_work.check_nodes,
        }, checker_times, .{
            .probes = resolve.fsProbeCount(),
            .lookups = rcache.lookups,
            .hits = rcache.hits,
            .enabled = !cli.no_resolve_cache,
            .nm_dirs = fs_counts.nm_dirs,
            .pkg_json = fs_counts.pkg_json,
            .real_dirs = fs_counts.real_dirs,
            .stat_files = fs_counts.stat_files,
            .pkg_exports = fs_counts.pkg_exports,
            .stat_lookups = rcache.fs.stat_lookups,
            .stat_hits = rcache.fs.stat_hits,
            .exports_lookups = rcache.fs.exports_lookups,
            .exports_hits = rcache.fs.exports_hits,
            .fs_bytes = rcache.fs.bytes,
        });
    }

    if (cli.memory) {
        // The shell measures; report.zig only formats. Every number below is
        // read here, in main, and handed over as a value.
        const worker_arena_bytes = try arena.alloc(usize, workers.len);
        for (workers, worker_arena_bytes) |*w, *cap| {
            cap.* = w.arena.queryCapacity() + w.scratch.queryCapacity();
        }
        const istats = interner.bytesUsed(io);
        var pack_text: usize = 0;
        var pack_reserved: usize = 0;
        for (workers) |*w| {
            pack_text += w.pack.text_bytes;
            pack_reserved += w.pack.reserved_bytes;
        }
        var checker_mem: std.ArrayList(ztsc.report.CheckerMem) = .empty;
        for (tasks, 0..) |*t, k| {
            const ck = t.result orelse continue;
            try checker_mem.append(arena, .{
                .index = k,
                .types = ck.stats.types_created,
                .type_bytes = ck.stats.type_bytes,
            });
        }
        try ztsc.report.printMemory(out, .{
            .worker_arena_bytes = worker_arena_bytes,
            .interner_total = istats.total(),
            .interner_strings = istats.string_bytes,
            .line_table_bytes = line_table_bytes,
            .token_bytes = token_bytes,
            .source_bytes = total_bytes,
            .pack_text = pack_text,
            .pack_reserved = pack_reserved,
            .tokens = total_tokens,
            .lines = total_lines,
            .nodes = total_nodes,
            .node_bytes = node_bytes,
            .extra_bytes = extra_bytes,
            .ast_token_bytes = ast_token_bytes,
            .symbols = total_symbols,
            .scopes = total_scopes,
            .flows = total_flows,
            .bind_symbol_bytes = bind_symbol_bytes,
            .bind_scope_bytes = bind_scope_bytes,
            .bind_flow_bytes = bind_flow_bytes,
            .bind_record_bytes = bind_record_bytes,
            .graph_bytes = prog.graphBytes(),
            .checkers = checker_mem.items,
            .check_types = check_types,
            .check_type_bytes = check_type_bytes,
            .rel_entries = check_rel_entries,
            .rel_bytes = check_rel_bytes,
            .rel_hits = check_rel_hits,
            .rel_misses = check_rel_misses,
            .inst_hits = check_inst_hits,
            .inst_misses = check_inst_misses,
            .inst_maps = check_inst_maps,
            .instantiations = check_instantiations,
            .nt_hits = check_nt_hits,
            .nt_misses = check_nt_misses,
            .scratch_high_water = check_scratch_hw,
            .flow_queries = check_flow_queries,
        });
    }

    try out.flush();
    for (tasks) |*t| t.arena.deinit();
    // Exit codes (documented in --help / README): 2 for environment
    // failures (unloadable files, internal checker errors), 1 when any
    // diagnostics were reported, 0 for a clean check.
    if (failed > 0) std.process.exit(2);
    if (config_diags.len > 0 or parse_diags > 0 or bind_diags > 0 or link_diags > 0 or check_diags > 0) std.process.exit(1);
}

/// Why an argument was rejected. One message per case, printed by main.
const ArgProblem = enum { unknown_flag, bad_value, missing_value };

/// What `parseArgs` produces: the settled CLI, or the first argument it could
/// not accept together with the reason. A returned value rather than an error
/// plus an out-parameter, so nothing has to be written on every loop iteration
/// to keep a diagnostic available for a failure that usually never happens.
const ParseResult = union(enum) {
    ok: Cli,
    bad: struct { problem: ArgProblem, arg: []const u8 },

    fn reject(problem: ArgProblem, arg: []const u8) ParseResult {
        return .{ .bad = .{ .problem = problem, .arg = arg } };
    }
};

/// Parse argv.
fn parseArgs(arena: std.mem.Allocator, args: []const [:0]const u8) error{OutOfMemory}!ParseResult {
    var cli: Cli = .{};
    var paths: std.ArrayList([]const u8) = .empty;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--timing")) {
            cli.timing = true;
        } else if (std.mem.eql(u8, arg, "--memory")) {
            cli.memory = true;
        } else if (std.mem.eql(u8, arg, "--dump-ast")) {
            cli.dump_ast = true;
        } else if (std.mem.eql(u8, arg, "--dump-symbols")) {
            cli.dump_symbols = true;
        } else if (std.mem.eql(u8, arg, "--dump-types")) {
            cli.dump_types = true;
        } else if (std.mem.eql(u8, arg, "--version")) {
            cli.version = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            cli.help = true;
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            cli.verbose = true;
        } else if (std.mem.eql(u8, arg, "--noLib")) {
            cli.no_lib = true;
        } else if (std.mem.eql(u8, arg, "--skip-default-lib-check")) {
            cli.skip_default_lib_check = true;
        } else if (std.mem.startsWith(u8, arg, "--lib=")) {
            var list: std.ArrayList([]const u8) = .empty;
            var it = std.mem.splitScalar(u8, arg["--lib=".len..], ',');
            while (it.next()) |name| {
                const t = std.mem.trim(u8, name, " \t");
                if (t.len > 0) try list.append(arena, t);
            }
            cli.lib = try list.toOwnedSlice(arena);
        } else if (std.mem.eql(u8, arg, "--no-resolve-cache")) {
            cli.no_resolve_cache = true;
        } else if (std.mem.eql(u8, arg, "--no-frozen-store")) {
            cli.no_frozen_store = true;
        } else if (std.mem.eql(u8, arg, "--no-inst-cache")) {
            cli.no_inst_cache = true;
        } else if (std.mem.eql(u8, arg, "--census")) {
            cli.census = true;
        } else if (std.mem.eql(u8, arg, "--inst-profile")) {
            cli.inst_profile = true;
        } else if (std.mem.eql(u8, arg, "--eager-members")) {
            cli.eager_members = true;
        } else if (std.mem.eql(u8, arg, "--alias-refs")) {
            cli.alias_refs = true;
        } else if (std.mem.eql(u8, arg, "--variance-decides")) {
            cli.variance_decides = true;
        } else if (std.mem.eql(u8, arg, "--decl-profile")) {
            cli.decl_profile = true;
        } else if (std.mem.eql(u8, arg, "--mem-profile")) {
            cli.mem_profile = true;
        } else if (std.mem.startsWith(u8, arg, "--inst-memo-bits=")) {
            cli.inst_memo_bits = std.fmt.parseInt(u6, arg["--inst-memo-bits=".len..], 10) catch
                return .reject(.bad_value, arg);
        } else if (std.mem.eql(u8, arg, "--dup-profile")) {
            cli.dup_profile = true;
        } else if (std.mem.startsWith(u8, arg, "--partition-file=")) {
            cli.partition_file = arg["--partition-file=".len..];
        } else if (std.mem.startsWith(u8, arg, "--file-order=")) {
            const v = arg["--file-order=".len..];
            if (std.mem.eql(u8, v, "source")) {
                cli.file_order = .{ .source = {} };
            } else if (std.mem.eql(u8, v, "reverse")) {
                cli.file_order = .{ .reverse = {} };
            } else if (std.mem.startsWith(u8, v, "shuffle=")) {
                cli.file_order = .{ .shuffle = std.fmt.parseInt(u64, v["shuffle=".len..], 10) catch
                    return .reject(.bad_value, arg) };
            } else if (std.mem.eql(u8, v, "shuffle")) {
                cli.file_order = .{ .shuffle = 1 };
            } else return .reject(.bad_value, arg);
        } else if (std.mem.eql(u8, arg, "--lazy-stats")) {
            cli.lazy_stats = true;
        } else if (std.mem.startsWith(u8, arg, "--inst-focus=")) {
            cli.inst_focus = std.fmt.parseInt(u32, arg["--inst-focus=".len..], 10) catch
                return .reject(.bad_value, arg);
            cli.inst_profile = true;
        } else if (std.mem.eql(u8, arg, "--pretty")) {
            cli.pretty = true;
        } else if (std.mem.startsWith(u8, arg, "--pretty=")) {
            const v = arg["--pretty=".len..];
            if (std.mem.eql(u8, v, "true")) {
                cli.pretty = true;
            } else if (std.mem.eql(u8, v, "false")) {
                cli.pretty = false;
            } else {
                return .reject(.bad_value, arg);
            }
        } else if (std.mem.eql(u8, arg, "--project") or std.mem.eql(u8, arg, "-p")) {
            i += 1;
            if (i >= args.len) return .reject(.missing_value, arg);
            cli.project = args[i];
        } else if (std.mem.startsWith(u8, arg, "--project=")) {
            cli.project = arg["--project=".len..];
        } else if (std.mem.startsWith(u8, arg, "--workers=")) {
            const n = std.fmt.parseInt(usize, arg["--workers=".len..], 10) catch
                return .reject(.bad_value, arg);
            if (n == 0) return .reject(.bad_value, arg);
            cli.workers = n;
        } else if (std.mem.startsWith(u8, arg, "--checkers=")) {
            const n = std.fmt.parseInt(usize, arg["--checkers=".len..], 10) catch
                return .reject(.bad_value, arg);
            if (n == 0) return .reject(.bad_value, arg);
            cli.checkers = n;
        } else if (std.mem.startsWith(u8, arg, "--repeat=")) {
            cli.repeat = std.fmt.parseInt(usize, arg["--repeat=".len..], 10) catch
                return .reject(.bad_value, arg);
            if (cli.repeat == 0) return .reject(.bad_value, arg);
        } else if (std.mem.startsWith(u8, arg, "-") and arg.len > 1) {
            return .reject(.unknown_flag, arg);
        } else {
            try paths.append(arena, arg);
        }
    }
    cli.paths = paths.items;
    return .{ .ok = cli };
}

/// `parseArgs` on a well-formed argv, or a test failure naming the argument
/// it rejected.
fn parseOk(arena: std.mem.Allocator, args: []const [:0]const u8) !Cli {
    return switch (try parseArgs(arena, args)) {
        .ok => |c| c,
        .bad => |b| {
            std.debug.print("parseArgs rejected '{s}' ({s})\n", .{ b.arg, @tagName(b.problem) });
            return error.TestUnexpectedResult;
        },
    };
}

/// Assert `args` is rejected for `problem` at argument `arg`.
fn expectRejected(
    arena: std.mem.Allocator,
    args: []const [:0]const u8,
    problem: ArgProblem,
    arg: []const u8,
) !void {
    switch (try parseArgs(arena, args)) {
        .ok => return error.TestUnexpectedResult,
        .bad => |b| {
            try std.testing.expectEqual(problem, b.problem);
            try std.testing.expectEqualStrings(arg, b.arg);
        },
    }
}

test "parseArgs flags and paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const args = [_][:0]const u8{ "ztsc", "--timing", "a.ts", "--memory", "b.ts" };
    const cli = try parseOk(arena.allocator(), &args);
    try std.testing.expect(cli.timing);
    try std.testing.expect(cli.memory);
    try std.testing.expect(!cli.version);
    try std.testing.expectEqual(@as(usize, 2), cli.paths.len);
    try std.testing.expectEqualStrings("a.ts", cli.paths[0]);
    try std.testing.expectEqualStrings("b.ts", cli.paths[1]);
}

test "parseArgs workers, checkers and repeat" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = [_][:0]const u8{ "ztsc", "--workers=4", "--checkers=2", "--repeat=10", "a.ts" };
    const cli = try parseOk(a, &args);
    try std.testing.expectEqual(@as(?usize, 4), cli.workers);
    try std.testing.expectEqual(@as(?usize, 2), cli.checkers);
    try std.testing.expectEqual(@as(usize, 10), cli.repeat);

    try expectRejected(a, &.{ "ztsc", "--workers=0" }, .bad_value, "--workers=0");
    try expectRejected(a, &.{ "ztsc", "--checkers=0" }, .bad_value, "--checkers=0");
    try expectRejected(a, &.{ "ztsc", "--repeat=x" }, .bad_value, "--repeat=x");
}

test "parseArgs rejects unknown flags" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectRejected(a, &.{ "ztsc", "--nope" }, .unknown_flag, "--nope");
    try expectRejected(a, &.{ "ztsc", "-x" }, .unknown_flag, "-x");
}

test "parseArgs tsconfig flags: pretty, project, help, verbose" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const a1 = [_][:0]const u8{ "ztsc", "--pretty", "--verbose", "a.ts" };
    const c1 = try parseOk(a, &a1);
    try std.testing.expectEqual(@as(?bool, true), c1.pretty);
    try std.testing.expect(c1.verbose);

    const a2 = [_][:0]const u8{ "ztsc", "--pretty=false" };
    const c2 = try parseOk(a, &a2);
    try std.testing.expectEqual(@as(?bool, false), c2.pretty);

    const a3 = [_][:0]const u8{"ztsc"};
    const c3 = try parseOk(a, &a3);
    try std.testing.expectEqual(@as(?bool, null), c3.pretty);

    const a4 = [_][:0]const u8{ "ztsc", "-p", "proj/dir" };
    const c4 = try parseOk(a, &a4);
    try std.testing.expectEqualStrings("proj/dir", c4.project.?);

    const a5 = [_][:0]const u8{ "ztsc", "--project=x/tsconfig.json" };
    const c5 = try parseOk(a, &a5);
    try std.testing.expectEqualStrings("x/tsconfig.json", c5.project.?);

    try expectRejected(a, &.{ "ztsc", "-p" }, .missing_value, "-p");
    try expectRejected(a, &.{ "ztsc", "--pretty=maybe" }, .bad_value, "--pretty=maybe");

    const a8 = [_][:0]const u8{ "ztsc", "-h" };
    const c8 = try parseOk(a, &a8);
    try std.testing.expect(c8.help);
}

test "effectiveOptions: the CLI overrides the tsconfig, and only where it says so" {
    const cfg: ztsc.tsconfig.Config = .{
        .path = "tsconfig.json",
        .dir = ".",
        .lib = &.{"es2015"},
        .skip_lib_check = true,
        .skip_all_lib_check = true,
        .allow_js = true,
        .no_implicit_any = false,
        .experimental_decorators = true,
        .resolve_json_module = true,
        .resolve_pkg_json_exports = false,
        .allow_synthetic_default_imports = false,
        .base_url = "src",
        .jsx_runtime_module = "react/jsx-runtime",
    };

    // No tsconfig: the documented bare-file-argument defaults. Bundler
    // resolution is why allowSyntheticDefaultImports starts true.
    const bare = effectiveOptions(.{}, null);
    try std.testing.expect(bare.allow_synthetic_default);
    try std.testing.expect(bare.no_implicit_any);
    try std.testing.expect(bare.resolve_pkg_json_exports);
    try std.testing.expect(!bare.skip_default_lib_check);
    try std.testing.expect(!bare.skip_all_dts_check);
    try std.testing.expectEqual(@as(?[]const u8, null), bare.jsx_runtime_module);

    // With a tsconfig and no overriding flags, every field is the config's.
    const from_cfg = effectiveOptions(.{}, cfg);
    try std.testing.expect(from_cfg.skip_default_lib_check);
    try std.testing.expect(from_cfg.skip_all_dts_check);
    try std.testing.expect(from_cfg.allow_js);
    try std.testing.expect(!from_cfg.no_implicit_any);
    try std.testing.expect(from_cfg.experimental_decorators);
    try std.testing.expect(from_cfg.resolve_json);
    try std.testing.expect(!from_cfg.resolve_pkg_json_exports);
    try std.testing.expect(!from_cfg.allow_synthetic_default);
    try std.testing.expectEqualStrings("src", from_cfg.base_url.?);
    try std.testing.expectEqualStrings("react/jsx-runtime", from_cfg.jsx_runtime_module.?);
    try std.testing.expectEqual(libs.resolveLibSet(&.{"es2015"}), from_cfg.lib_set);

    // `--skip-default-lib-check` is a tri-state: absent leaves the config's
    // value (above), present wins in EITHER direction — and it never touches
    // the skipLibCheck superset, which only a tsconfig can set.
    try std.testing.expect(!effectiveOptions(.{ .skip_default_lib_check = false }, cfg).skip_default_lib_check);
    try std.testing.expect(effectiveOptions(.{ .skip_default_lib_check = false }, cfg).skip_all_dts_check);
    try std.testing.expect(effectiveOptions(.{ .skip_default_lib_check = true }, null).skip_default_lib_check);
    try std.testing.expect(!effectiveOptions(.{ .skip_default_lib_check = true }, null).skip_all_dts_check);

    // Lib precedence: --noLib beats everything, then --lib, then the config.
    try std.testing.expectEqual(libs.LibSet.none, effectiveOptions(.{ .no_lib = true, .lib = &.{"dom"} }, cfg).lib_set);
    try std.testing.expectEqual(
        libs.resolveLibSet(&.{"dom"}),
        effectiveOptions(.{ .lib = &.{"dom"} }, cfg).lib_set,
    );
    try std.testing.expectEqual(libs.resolveLibSet(null), effectiveOptions(.{}, null).lib_set);
}

test "arena accounting sanity: capacity grows with allocations and covers usage" {
    var a = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer a.deinit();
    try std.testing.expectEqual(@as(usize, 0), a.queryCapacity());
    var total: usize = 0;
    for (0..100) |i| {
        const n = 128 + i;
        _ = try a.allocator().alloc(u8, n);
        total += n;
    }
    try std.testing.expect(a.queryCapacity() >= total);
}
