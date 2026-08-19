//! The per-file `@jsxImportSource` pragma.
//!
//! `/* @jsxImportSource preact */` at the top of a `.tsx` file overrides the
//! project's `jsxImportSource` for that file alone: its JSX tags read the `JSX`
//! namespace out of `preact/jsx-runtime` and, when that module does not
//! resolve, it is `preact/jsx-runtime` that TS2875 names. One file can pick
//! preact while its neighbour picks react, which is why this cannot live on the
//! `Program`-wide `jsx_runtime_module`.
//!
//! Two rules, both tsc's (`processCommentPragmas` / `getJSXImplicitImportBase`)
//! and both easy to get wrong:
//!
//! - **Leading comments only.** Pragmas are read from the comment block before
//!   the file's first token, exactly like `/// <reference>` directives.
//! - **Block comments only.** `jsximportsource` is a `PragmaKindFlags.MultiLine`
//!   pragma, so `// @jsxImportSource preact` is inert — only `/* … */` and
//!   `/** … */` carry it. The LAST one in the block wins.
//!
//! The scan is a few hundred bytes per file (it stops at the first real token)
//! and allocates nothing: the returned name slices the source.

const std = @import("std");

/// The `@jsxImportSource` name pragma-set on `src`, or null when the file has
/// none. Slices `src`; the caller appends `/jsx-runtime` to get the specifier.
///
/// tsc's regex is `/@(\S+)(\s+.*)?$/gim` over each block comment's full text,
/// with the pragma's single `factory` argument taken as the first
/// whitespace-delimited word of the match's tail. That is reproduced here
/// rather than approximated, because the difference is observable: the
/// `@(\S+)` run is greedy, so `@jsxImportSourceFoo` names a *different*
/// (unknown) pragma and contributes nothing, and the tail is bounded by the end
/// of the LINE, so a pragma on one line of a multi-line comment cannot swallow
/// the next.
pub fn scan(src: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    var i: usize = 0;
    while (i < src.len) {
        while (i < src.len and (src[i] == ' ' or src[i] == '\t' or src[i] == '\r' or src[i] == '\n')) i += 1;
        if (i + 1 >= src.len or src[i] != '/') break; // first real token
        if (src[i + 1] == '/') {
            // Single-line comment: never carries a multi-line pragma.
            while (i < src.len and src[i] != '\n') i += 1;
            continue;
        }
        if (src[i + 1] != '*') break; // first real token
        const body_start = i;
        i += 2;
        while (i + 1 < src.len and !(src[i] == '*' and src[i + 1] == '/')) i += 1;
        i = if (i + 1 < src.len) i + 2 else src.len;
        if (scanComment(src[body_start..i])) |name| found = name;
        continue;
    }
    return found;
}

/// Last `@jsxImportSource <name>` in one block comment's text, or null.
fn scanComment(text: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, text, i, '@')) |at| {
        // `@(\S+)`: the pragma name runs to the next whitespace.
        var end = at + 1;
        while (end < text.len and !std.ascii.isWhitespace(text[end])) end += 1;
        // `$` bounds the tail at the end of this line.
        const line_end = std.mem.indexOfScalarPos(u8, text, end, '\n') orelse text.len;
        if (std.ascii.eqlIgnoreCase(text[at + 1 .. end], "jsximportsource")) {
            // `(\s+.*)?` — a name with no whitespace after it has no argument.
            if (end < line_end) {
                const tail = std.mem.trim(u8, text[end..line_end], " \t\r");
                var words = std.mem.tokenizeAny(u8, tail, " \t\r");
                if (words.next()) |w| found = w;
            }
        }
        i = if (line_end > at) line_end else at + 1;
    }
    return found;
}

test "scan: block-comment pragma, last one wins, leading block only" {
    try std.testing.expectEqualStrings("preact", scan("/* @jsxImportSource preact */\nconst a = <div/>;").?);
    try std.testing.expectEqualStrings("@emotion/react", scan(
        \\/// <reference path="react.d.ts" />
        \\/* eslint-disable react/x -- Unaware of @jsxImportSource */
        \\/** @jsxImportSource @emotion/react */
        \\import { css } from "@emotion/react";
    ).?);
    // `//` is inert, and so is a pragma after the first token.
    try std.testing.expectEqual(@as(?[]const u8, null), scan("// @jsxImportSource preact\nconst a = 1;"));
    try std.testing.expectEqual(@as(?[]const u8, null), scan("const a = 1;\n/* @jsxImportSource preact */"));
    // Greedy `\S+`: this names an unknown pragma, not `jsximportsource`.
    try std.testing.expectEqual(@as(?[]const u8, null), scan("/* @jsxImportSourceX preact */\n"));
    // No argument at all.
    try std.testing.expectEqual(@as(?[]const u8, null), scan("/* @jsxImportSource\n */\n"));
}
