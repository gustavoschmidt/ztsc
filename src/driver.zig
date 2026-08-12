//! The front-end driver: everything between "here are the root paths" and
//! "here is a linked `Program`".
//!
//! Discovery is single-owner with a completion queue: the caller's thread is
//! the sole owner of the module graph and seen-set (no locks on graph state);
//! workers run the whole per-file front end (load/parse/bind) and push per-file
//! completion messages `(file, import specifiers)`; the owner resolves each
//! completion's module specifiers (bundler-style, see modules.zig) as it
//! arrives and enqueues newly discovered files immediately — no wave barrier,
//! so already-discovered work never waits on an unrelated slow file.
//!
//! After discovery, files are renumbered into a deterministic graph-derived
//! order (BFS from the entry files, tie-break = specifier order within the
//! importing file) and the atoms the concurrent front end handed out are
//! reassigned to the ids a single-threaded front end would have produced. Both
//! are what make the result independent of worker scheduling; see the two
//! blocks below for why each is needed. A serial `link` phase then builds the
//! sealed per-file import/export tables.

const std = @import("std");
const Io = std.Io;

/// Minimal monotonic wall-clock timer over std.Io's clock API. Every phase
/// this driver reports, and every checker instance (schedule.zig), measures
/// itself with one.
pub const Timer = struct {
    io: Io,
    start_ts: Io.Clock.Timestamp,

    pub fn start(io: Io) Timer {
        return .{ .io = io, .start_ts = .now(io, .awake) };
    }

    pub fn readNs(t: *const Timer) u64 {
        const d = t.start_ts.untilNow(t.io);
        const ns = d.raw.nanoseconds;
        return if (ns > 0) @intCast(ns) else 0;
    }
};

/// How the program's root file list is ordered before it is seeded. The
/// order is supposed to be unobservable — this exists so a gate can prove it.
pub const FileOrder = union(enum) {
    /// As the tsconfig `include` walk (or the command line) produced it.
    source: void,
    /// Exactly reversed. The cheapest permutation that moves every file.
    reverse: void,
    /// A seeded Fisher-Yates deal, so a failing order is reproducible from
    /// the seed alone.
    shuffle: u64,
};
