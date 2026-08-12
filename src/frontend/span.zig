//! Source positions: a byte range and a line/column pair.
//!
//! Split out of source.zig so the many modules that only need to *name* a
//! position (diagnostics, the AST, the checker, the renderer) do not have to
//! pull in file loading, mmap and the pack allocator. source.zig re-exports
//! both types, so either import works.

/// A half-open byte range [start, end) into a source file.
pub const Span = struct {
    start: u32,
    end: u32,

    pub fn len(s: Span) u32 {
        return s.end - s.start;
    }
};

/// Zero-based line/column position.
pub const LineCol = struct {
    line: u32,
    col: u32,
};
