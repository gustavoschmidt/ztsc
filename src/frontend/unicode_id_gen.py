import sys, unicodedata

# ECMAScript UnicodeIDStart / UnicodeIDContinue (ES2015+ ID_Start / ID_Continue).
START_CATS = {"Lu", "Ll", "Lt", "Lm", "Lo", "Nl"}
CONT_EXTRA = {"Mn", "Mc", "Nd", "Pc"}
# Other_ID_Start / Other_ID_Continue (PropList.txt), stable across versions.
OTHER_ID_START = {0x1885, 0x1886, 0x2118, 0x212E, 0x309B, 0x309C}
OTHER_ID_CONTINUE = {0x00B7, 0x0387, 0x1369, 0x136A, 0x136B, 0x136C, 0x136D,
                     0x136E, 0x136F, 0x1370, 0x1371, 0x19DA}
# Pattern_Syntax / Pattern_White_Space are excluded from ID_Start/ID_Continue.
PATTERN_SYNTAX = {0x2E2F}
# ZWNJ / ZWJ are IdentifierPart in ECMAScript but not ID_Continue.
ZW = {0x200C, 0x200D}

LO, HI = 0x80, 0x110000


def is_start(cp):
    if cp in PATTERN_SYNTAX:
        return False
    return unicodedata.category(chr(cp)) in START_CATS or cp in OTHER_ID_START


def is_cont(cp):
    if cp in ZW:
        return True
    if is_start(cp):
        return True
    if cp in PATTERN_SYNTAX:
        return False
    return unicodedata.category(chr(cp)) in CONT_EXTRA or cp in OTHER_ID_CONTINUE


def ranges(pred):
    out, lo = [], None
    for cp in range(LO, HI):
        if pred(cp):
            if lo is None:
                lo = cp
        elif lo is not None:
            out.append((lo, cp - 1))
            lo = None
    if lo is not None:
        out.append((lo, HI - 1))
    return out


def emit(name, rs):
    print(f"const {name}: [{len(rs)}]Range = .{{")
    for i in range(0, len(rs), 4):
        row = "".join(f" .{{ .lo = 0x{a:X}, .hi = 0x{b:X} }}," for a, b in rs[i:i + 4])
        print("   " + row)
    print("};")
    print()


print("//! Unicode ID_Start / ID_Continue ranges above ASCII — GENERATED, do not")
print("//! hand-edit.")
print("//!")
print("//! The scanner's ASCII fast path answers every byte below 0x80 without")
print("//! looking here, so the tables start at U+0080.")
print("//!")
print("//! Regenerate (needs no network — the ranges come out of the Python")
print("//! runtime's own Unicode database) with")
print("//!")
print("//!     python3 src/frontend/unicode_id_gen.py > src/frontend/unicode_id.zig")
print("//!")
print(f"//! then `zig fmt src/frontend/unicode_id.zig`. Written from Unicode")
print(f"//! {unicodedata.unidata_version}: the script derives ID_Start from the general")
print("//! categories L*/Nl plus Other_ID_Start, and ID_Continue from those plus")
print("//! Mn/Mc/Nd/Pc, Other_ID_Continue and ZWNJ/ZWJ — which is how the")
print("//! ECMAScript grammar spells IdentifierStart/IdentifierPart.")
print("//!")
print("//! A NEWER Unicode database only ever ADDS code points (the identifier")
print("//! properties are stability-guaranteed), so a table built from a later")
print("//! version than the one tsc tabled stays a superset of tsc's: it can")
print("//! under-report TS1127 on a character added since, never invent one.")
print()
print("const Range = struct { lo: u21, hi: u21 };")
print()
emit("id_start", ranges(is_start))
emit("id_continue", ranges(is_cont))

print('''/// Is `cp` (always >= 0x80 — the caller's ASCII path answers the rest) an
/// ECMAScript IdentifierStart?
pub fn isStart(cp: u21) bool {
    return inRanges(&id_start, cp);
}

/// Is `cp` (always >= 0x80) an ECMAScript IdentifierPart?
pub fn isContinue(cp: u21) bool {
    return inRanges(&id_continue, cp);
}

fn inRanges(table: []const Range, cp: u21) bool {
    var lo: usize = 0;
    var hi: usize = table.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const r = table[mid];
        if (cp < r.lo) {
            hi = mid;
        } else if (cp > r.hi) {
            lo = mid + 1;
        } else {
            return true;
        }
    }
    return false;
}''')
