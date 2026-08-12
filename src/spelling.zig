//! "Did you mean …?" — tsc's `getSpellingSuggestion`, ported.
//!
//! Pure string code: a weighted Levenshtein distance in fixed-point tenths
//! plus tsc's admissibility filters. Nothing here knows about atoms, shards or
//! interning — the checker and the linker reach for it whenever a lookup fails
//! and a near-miss name would make the diagnostic useful.

const std = @import("std");
const Allocator = std.mem.Allocator;

fn asciiLower(ch: u8) u8 {
    return if (ch >= 'A' and ch <= 'Z') ch + 32 else ch;
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (asciiLower(x) != asciiLower(y)) return false;
    return true;
}

/// Weighted Levenshtein in tenths (fixed-point ×10), replicating tsc's
/// `levenshteinWithMax` costs: exact (case-sensitive) match 0, case-insensitive
/// substitution 1, other substitution 20, insert/delete 10. Full DP (no
/// diagonal banding): for any true distance within `cap_tenths` the banded and
/// unbanded results are identical, so this is exact where it matters. Returns
/// the distance, or null when it exceeds `cap_tenths`. `scratch` must hold at
/// least `2 * (b.len + 1)` usize slots.
fn weightedLevTenths(a: []const u8, b: []const u8, cap_tenths: usize, scratch: []usize) ?usize {
    var prev = scratch[0 .. b.len + 1];
    var cur = scratch[b.len + 1 .. 2 * (b.len + 1)];
    for (0..b.len + 1) |j| prev[j] = j * 10;
    var i: usize = 1;
    while (i <= a.len) : (i += 1) {
        cur[0] = i * 10;
        var col_min = cur[0];
        var j: usize = 1;
        while (j <= b.len) : (j += 1) {
            const dist = if (a[i - 1] == b[j - 1]) prev[j - 1] else blk: {
                const sub = if (asciiLower(a[i - 1]) == asciiLower(b[j - 1])) prev[j - 1] + 1 else prev[j - 1] + 20;
                break :blk @min(@min(prev[j] + 10, cur[j - 1] + 10), sub);
            };
            cur[j] = dist;
            col_min = @min(col_min, dist);
        }
        if (col_min > cap_tenths) return null;
        const tmp = prev;
        prev = cur;
        cur = tmp;
    }
    const res = prev[b.len];
    return if (res > cap_tenths) null else res;
}

/// tsc's initial `bestDistance` for a name of `name_len` characters —
/// `floor(len*0.4)+1` — expressed in tenths as an INCLUSIVE acceptance bound
/// (tsc compares against `bestDistance - 0.1`, so the largest distance that
/// still qualifies is one tenth below the bound itself).
pub fn spellInitialCapTenths(name_len: usize) usize {
    return (name_len * 40 / 100 + 1) * 10 - 1;
}

/// The distance ONE candidate scores against `name` under tsc's
/// `getSpellingSuggestion` rules, or null when the candidate is inadmissible
/// or scores worse than `cap_tenths`. Split out of `spellingSuggestion` for
/// the callers that own their candidate iteration (the checker's scope walk
/// and property walk, which need their own deterministic tie-break and a
/// shrinking bound). `scratch` must hold at least `2 * (cand.len + 1)` slots.
///
/// The admissibility filters are tsc's, in tsc's order: the
/// `maximumLengthDifference = max(2, floor(len*0.34))` length pre-filter, the
/// identical-name skip, and the rule that a candidate under three characters
/// only competes when it differs from `name` by CASE alone.
pub fn spellCandidateDistance(name: []const u8, cand: []const u8, cap_tenths: usize, scratch: []usize) ?usize {
    const max_len_diff: usize = @max(2, name.len * 34 / 100);
    const diff = if (cand.len > name.len) cand.len - name.len else name.len - cand.len;
    if (diff > max_len_diff) return null;
    if (std.mem.eql(u8, cand, name)) return null;
    if (cand.len < 3 and !eqlIgnoreCase(cand, name)) return null;
    return weightedLevTenths(name, cand, cap_tenths, scratch);
}

/// tsc's `getSpellingSuggestion` (core.ts): pick the closest candidate name to
/// `name` under the weighted edit distance, or null when none is close enough.
/// Thresholds match tsc exactly — see `spellCandidateDistance` and
/// `spellInitialCapTenths`. Ties on distance are broken toward the
/// lexicographically-smaller name so the choice is stable across --workers
/// (the determinism contract), where tsc would take iteration order.
/// Returns the winning index into `candidates`, or null.
pub fn spellingSuggestion(gpa: Allocator, name: []const u8, candidates: []const []const u8) ?usize {
    if (name.len == 0) return null;
    // The bound is FIXED here (not lowered as tsc does) so every qualifying
    // candidate competes; the global minimum is then chosen with a
    // deterministic lexicographic tie-break. This yields tsc's global-minimum
    // pick while staying byte-identical across --workers regardless of
    // candidate iteration order.
    const cap: usize = spellInitialCapTenths(name.len);
    var best: ?usize = null;
    var best_d: usize = undefined;
    // DP scratch sized for the longest candidate.
    var max_cand: usize = 0;
    for (candidates) |c| max_cand = @max(max_cand, c.len);
    const scratch = gpa.alloc(usize, 2 * (max_cand + 1)) catch return null;
    defer gpa.free(scratch);
    for (candidates, 0..) |cand, i| {
        const d = spellCandidateDistance(name, cand, cap, scratch) orelse continue;
        if (best == null or d < best_d or
            (d == best_d and std.mem.order(u8, cand, candidates[best.?]) == .lt))
        {
            best_d = d;
            best = i;
        }
    }
    return best;
}

test "spellingSuggestion: matches tsc getSpellingSuggestion verdicts" {
    const gpa = std.testing.allocator;
    // String-literal union suggestion (TS2820 path): the close member wins.
    try std.testing.expectEqual(
        @as(?usize, 2),
        spellingSuggestion(gpa, "assignment-late", &.{ "account-balance", "add", "assignment" }),
    );
    // No near match -> null (plain TS2322/TS2305, no "Did you mean").
    try std.testing.expectEqual(
        @as(?usize, null),
        spellingSuggestion(gpa, "upload-file", &.{ "account-balance", "add", "assignment" }),
    );
    // A single-character export typo is within threshold (TS2724 path).
    try std.testing.expectEqual(
        @as(?usize, 0),
        spellingSuggestion(gpa, "CattleHealthStatusBadge", &.{"CattleHealthStatusBadgeX"}),
    );
    // A distant export name is rejected — matches tsc emitting plain TS2305
    // for `CattleHealthStatusBadge` vs only `CattleWeighingStatusBadge`.
    try std.testing.expectEqual(
        @as(?usize, null),
        spellingSuggestion(gpa, "CattleHealthStatusBadge", &.{"CattleWeighingStatusBadge"}),
    );
    // Candidates shorter than 3 chars only match on case.
    try std.testing.expectEqual(
        @as(?usize, null),
        spellingSuggestion(gpa, "ab", &.{"xy"}),
    );
    // Empty candidate set.
    try std.testing.expectEqual(@as(?usize, null), spellingSuggestion(gpa, "foo", &.{}));
}
