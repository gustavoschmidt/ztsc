//! Checker tests (moved verbatim from checker.zig).

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const scanner = @import("../frontend/scanner.zig");
const intern = @import("../intern.zig");
const binder = @import("../frontend/binder.zig");
const types = @import("../types.zig");
const source = @import("../frontend/source.zig");
const libs = @import("../libs.zig");
const modules = @import("../link/modules.zig");
const ZeroPagedArray = @import("../zeropage.zig").ZeroPagedArray;

const Io = std.Io;
const Ast = ast.Ast;
const Atom = intern.Atom;
const Interner = intern.Interner;
const Bind = binder.Bind;
const SymbolId = binder.SymbolId;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const Check = checker_zig.Check;
const check = checker_zig.check;
const checkFiles = checker_zig.checkFiles;

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const parser = @import("../frontend/parser.zig");

const TestCheck = struct {
    arena: std.heap.ArenaAllocator,
    interner: Interner,
    result: Check,

    pub fn init(src: []const u8) !TestCheck {
        var t: TestCheck = undefined;
        t.arena = std.heap.ArenaAllocator.init(testing.allocator);
        errdefer t.arena.deinit();
        t.interner = Interner.init();
        errdefer t.interner.deinit(testing.allocator);
        const alloc = t.arena.allocator();
        const tree = try alloc.create(Ast);
        tree.* = try parser.parse(alloc, src);
        const bound = try alloc.create(Bind);
        bound.* = try binder.bind(alloc, testing.io, testing.allocator, &t.interner, tree, src, false);
        t.result = try check(alloc, testing.io, testing.allocator, &t.interner, tree, bound, src);
        return t;
    }

    pub fn deinit(t: *TestCheck) void {
        t.interner.deinit(testing.allocator);
        t.arena.deinit();
    }
};

/// Expect exactly these tsc codes, in span order.
fn expectCodes(src: []const u8, expected: []const u16) !void {
    var t = try TestCheck.init(src);
    defer t.deinit();
    var ok = t.result.diagnostics.len == expected.len;
    if (ok) {
        for (expected, t.result.diagnostics) |want, got| {
            if (want != got.code) ok = false;
        }
    }
    if (!ok) {
        std.debug.print("--- source: {s}\n--- got {d} diagnostics:\n", .{ src, t.result.diagnostics.len });
        for (t.result.diagnostics) |dd| {
            std.debug.print("  TS{d} [{d}..{d}] {s}\n", .{ dd.code, dd.span.start, dd.span.end, dd.msg });
        }
        return error.TestExpectedEqual;
    }
}

fn expectClean(src: []const u8) !void {
    try expectCodes(src, &.{});
}

test "smoke: assignability basics" {
    try expectClean("const a: number = 1; const b: string = \"x\"; let c: boolean = true;");
    try expectCodes("const a: string = 1;", &.{2322});
    try expectCodes("let x: number = 1; x = \"nope\";", &.{2322});
}

test "assignability matrix: intrinsics and literals" {
    // literals -> primitives
    try expectClean("const s: string = \"a\"; const n: number = 1; const b: boolean = true;");
    try expectClean("const t: true = true; const u: \"a\" = \"a\"; const v: 1 = 1;");
    try expectCodes("const t: true = false;", &.{2322});
    try expectCodes("const u: \"a\" = \"b\";", &.{2322});
    // null/undefined strictness
    try expectCodes("const n: number = null;", &.{2322});
    try expectCodes("const n: number = undefined;", &.{2322});
    try expectClean("const n: number | null = null;");
    try expectClean("const v: void = undefined;");
    try expectCodes("const u: undefined = null;", &.{2322});
    // any / unknown / never
    try expectClean("declare const a: any; const n: number = a;");
    try expectClean("let u: unknown; u = 1; u = \"x\"; u = null;");
    try expectCodes("declare const u: unknown; const n: number = u;", &.{2322});
    try expectClean("declare const nv: never; const n: number = nv;");
}

test "assignability: unions" {
    try expectClean("let x: string | number = 1; x = \"a\";");
    try expectCodes("let x: string | number = true;", &.{2322});
    try expectClean("declare const a: string; const u: string | number = a;");
    try expectCodes("declare const u: string | number; const s: string = u;", &.{2322});
    try expectClean("declare const u: \"a\" | \"b\"; const s: string = u;");
    try expectClean("type AB = \"a\" | \"b\"; type ABC = AB | \"c\"; declare const x: AB; const y: ABC = x;");
}

test "assignability: objects, width and optionality" {
    try expectClean("interface P { x: number; y: number; } declare const p: { x: number; y: number; z: string }; const q: P = p;");
    try expectCodes("interface P { x: number; y: number; } declare const p: { x: number }; const q: P = p;", &.{2741});
    try expectCodes("interface P { x: number; y: number; } const q: P = {} as { a: 1 };", &.{2739});
    try expectClean("interface P { x?: number; } declare const p: {}; const q: P = p;");
    try expectCodes("interface P { x: number; } declare const p: { x?: number }; const q: P = p;", &.{2322});
    try expectClean("interface P { x?: number; } declare const p: { x: number }; const q: P = p;");
}

test "assignability: arrays and tuples" {
    try expectClean("const a: number[] = [1, 2, 3];");
    try expectCodes("const a: number[] = [1, \"x\"];", &.{2322});
    try expectClean("const t: [number, string] = [1, \"a\"];");
    try expectCodes("const t: [number, string] = [1];", &.{2322});
    try expectCodes("const t: [number] = [1, 2];", &.{2322});
    // tuple -> array
    try expectClean("declare const t: [number, number]; const a: number[] = t;");
    try expectCodes("declare const t: [number, string]; const a: number[] = t;", &.{2322});
    // array -> tuple: no
    try expectCodes("declare const a: number[]; const t: [number] = a;", &.{2322});
    // Source may have more elements than the target allows (tsc errors).
    try expectCodes("declare const t: [number, string?]; const u: [number] = t;", &.{2322});
    try expectClean("declare const t: [number]; const u: [number, string?] = t;");
}

test "assignability: functions (strictFunctionTypes)" {
    // Param contravariance for function types.
    try expectClean("type F = (x: string | number) => void; declare const f: (x: string | number | boolean) => void; const g: F = f;");
    try expectCodes("type F = (x: string | number) => void; declare const f: (x: string) => void; const g: F = f;", &.{2322});
    // Return covariance.
    try expectClean("type F = () => string | number; declare const f: () => string; const g: F = f;");
    try expectCodes("type F = () => string; declare const f: () => string | number; const g: F = f;", &.{2322});
    // Fewer params ok, more required params not.
    try expectClean("type F = (a: number, b: string) => void; declare const f: (a: number) => void; const g: F = f;");
    try expectCodes("type F = (a: number) => void; declare const f: (a: number, b: string) => void; const g: F = f;", &.{2322});
    // void target return accepts anything.
    try expectClean("type F = () => void; declare const f: () => number; const g: F = f;");
    // Method bivariance.
    try expectClean(
        \\interface Emitter { on(x: string | number): void; }
        \\declare const e: { on(x: string): void };
        \\const m: Emitter = e;
    );
}

test "assignability: recursive interface terminates" {
    try expectClean(
        \\interface Tree { value: number; next: Tree | null; }
        \\interface Tree2 { value: number; next: Tree2 | null; }
        \\declare const a: Tree;
        \\const b: Tree2 = a;
    );
    try expectCodes(
        \\interface Tree { value: number; next: Tree | null; }
        \\interface Tree2 { value: string; next: Tree2 | null; }
        \\declare const a: Tree;
        \\const b: Tree2 = a;
    , &.{2322});
}

test "excess property checking: fresh literals only" {
    try expectCodes("const p: { a: number } = { a: 1, b: 2 };", &.{2353});
    try expectClean("const tmp = { a: 1, b: 2 }; const p: { a: number } = tmp;");
    try expectCodes("interface P { a: number; } function f(p: P): void {} f({ a: 1, extra: true });", &.{2353});
    // Union target: property known in one constituent.
    try expectClean("type U = { a: number } | { b: string }; const u: U = { a: 1 };");
    try expectCodes("type U = { a: number } | { b: string }; const u: U = { a: 1, c: 2 };", &.{2353});
    // Index signature target admits extras.
    try expectClean("const p: { a: number; [k: string]: number } = { a: 1, b: 2 };");
}

test "literal widening: let vs const, annotation vs fresh" {
    try expectClean("const x = \"a\"; const y: \"a\" = x;");
    // let widens fresh literals -> string.
    try expectCodes("let x = \"a\"; const y: \"a\" = x;", &.{2322});
    // Annotated const gives non-widening literal.
    try expectClean("const x: \"a\" = \"a\"; let y = x; const z: \"a\" = y;");
    // const-forwarded fresh literal widens at let.
    try expectCodes("const x = \"a\"; let y = x; const z: \"a\" = y;", &.{2322});
    // Object literal props widen.
    try expectCodes("const o = { s: \"a\" }; const t: { s: \"a\" } = o;", &.{2322});
    try expectClean("const o: { s: \"a\" } = { s: \"a\" };");
}

test "narrowing: truthiness" {
    try expectClean(
        \\function f(x: string | null): string {
        \\  if (x) { return x; }
        \\  return "";
        \\}
    );
    try expectCodes(
        \\function f(x: string | null): string {
        \\  if (x) {}
        \\  return x;
        \\}
    , &.{2322});
    try expectClean(
        \\function f(x: { a: number } | undefined): number {
        \\  if (!x) { return 0; }
        \\  return x.a;
        \\}
    );
}

test "narrowing: typeof guards incl. else branch" {
    try expectClean(
        \\function f(x: string | number): number {
        \\  if (typeof x === "string") { return x.length; }
        \\  return x;
        \\}
    );
    try expectClean(
        \\function f(x: string | number | boolean): number {
        \\  if (typeof x === "string") { return 0; }
        \\  if (typeof x === "boolean") { return 1; }
        \\  return x;
        \\}
    );
    try expectCodes(
        \\function f(x: string | number): number {
        \\  if (typeof x === "string") { return x; }
        \\  return x;
        \\}
    , &.{2322});
}

test "narrowing: equality with literals and null/undefined" {
    try expectClean(
        \\function f(x: "a" | "b" | null): "b" {
        \\  if (x === null) { return "b"; }
        \\  if (x === "a") { return "b"; }
        \\  return x;
        \\}
    );
    try expectClean(
        \\function f(x: number | null | undefined): number {
        \\  if (x == null) { return 0; }
        \\  return x;
        \\}
    );
    try expectClean(
        \\function f(x: number | null | undefined): number {
        \\  if (x !== undefined && x !== null) { return x; }
        \\  return 0;
        \\}
    );
}

test "narrowing: discriminated unions incl. switch and never" {
    try expectClean(
        \\interface Circle { kind: "circle"; radius: number; }
        \\interface Square { kind: "square"; side: number; }
        \\type Shape = Circle | Square;
        \\function area(s: Shape): number {
        \\  if (s.kind === "circle") { return s.radius * s.radius; }
        \\  return s.side * s.side;
        \\}
    );
    try expectClean(
        \\interface Circle { kind: "circle"; radius: number; }
        \\interface Square { kind: "square"; side: number; }
        \\type Shape = Circle | Square;
        \\function area(s: Shape): number {
        \\  switch (s.kind) {
        \\    case "circle": return s.radius;
        \\    case "square": return s.side;
        \\  }
        \\}
    );
    try expectCodes(
        \\interface Circle { kind: "circle"; radius: number; }
        \\interface Square { kind: "square"; side: number; }
        \\type Shape = Circle | Square;
        \\function f(s: Shape): number {
        \\  if (s.kind === "circle") { return s.side; }
        \\  return 0;
        \\}
    , &.{2339});
    // never via exhaustion
    try expectClean(
        \\function f(x: "a" | "b"): number {
        \\  switch (x) {
        \\    case "a": return 0;
        \\    case "b": return 1;
        \\    default: {
        \\      const n: never = x;
        \\      return n;
        \\    }
        \\  }
        \\}
    );
}

test "narrowing: in / instanceof / optional chain" {
    try expectClean(
        \\type U = { swim: () => void } | { fly: () => void };
        \\function f(u: U): void {
        \\  if ("swim" in u) { u.swim(); } else { u.fly(); }
        \\}
    );
    try expectClean(
        \\class A { a: number = 1; }
        \\class B { b: string = ""; }
        \\function f(x: A | B): number {
        \\  if (x instanceof A) { return x.a; }
        \\  return x.b.length;
        \\}
    );
    try expectClean(
        \\interface Box { inner?: { value: number }; }
        \\function f(b: Box): number {
        \\  if (b.inner) { return b.inner.value; }
        \\  return 0;
        \\}
    );
}

test "narrowing: PathElem tag fold is lossless and keeps RefQ at 24 bytes" {
    const PE = Checker.PathElem;
    // The point of the fold: one word per link, 24 bytes per interned key.
    try testing.expectEqual(@as(usize, 4), @sizeOf(PE));
    try testing.expectEqual(@as(usize, 24), @sizeOf(Checker.RefQ));
    // Round-trips, and the three tags never alias on a shared payload.
    try testing.expectEqual(@as(Atom, 7), PE.member(7).atom());
    try testing.expectEqual(@as(u32, 7), PE.element(7).index());
    try testing.expectEqual(@as(u32, 7), PE.elementSym(7).indexSym());
    try testing.expect(!PE.member(7).isIndex());
    try testing.expect(!PE.member(7).isIndexSym());
    try testing.expect(PE.element(7).isIndex());
    try testing.expect(!PE.element(7).isIndexSym());
    try testing.expect(PE.elementSym(7).isIndex());
    try testing.expect(PE.elementSym(7).isIndexSym());
    try testing.expect(PE.member(7).bits != PE.element(7).bits);
    try testing.expect(PE.element(7).bits != PE.elementSym(7).bits);
    try testing.expect(PE.member(7).bits != PE.elementSym(7).bits);
    // A trailing slot past `len` is canonically a zero-atom member link, so
    // `RefKey`'s default and `member(0)` stay the same key (as before the fold).
    try testing.expectEqual(PE.member(0).bits, (PE{}).bits);
    // The 30-bit bound is checked, not assumed.
    try testing.expect(PE.memberFits(PE.payload_max));
    try testing.expect(!PE.memberFits(PE.payload_max + 1));
    try testing.expect(!PE.memberFits(std.math.maxInt(Atom)));
    try testing.expect(PE.symFits(PE.payload_max));
    try testing.expect(!PE.symFits(PE.payload_max + 1));
}

test "narrowing: assignment narrowing and loop widening" {
    try expectClean(
        \\let x: string | number = "a";
        \\const s: string = x;
        \\x = 1;
        \\const n: number = x;
    );
    try expectCodes(
        \\let x: string | number = "a";
        \\x = 1;
        \\const s: string = x;
    , &.{2322});
    // Loop back-edge resets to declared type.
    try expectCodes(
        \\declare const cond: boolean;
        \\let x: string | number = "a";
        \\while (cond) {
        \\  const s: string = x;
        \\  x = 1;
        \\}
    , &.{2322});
}

test "possibly nullish access (18047/18048/2532)" {
    try expectCodes("declare const s: string | undefined; s.length;", &.{18048});
    try expectCodes("declare const s: string | null; s.length;", &.{18047});
    try expectCodes("declare const s: string | null | undefined; s.length;", &.{18049});
    try expectClean("declare const s: string | undefined; s?.length;");
    try expectClean("declare const s: string | undefined; const n: number | undefined = s?.length;");
}

test "calls: arity, arguments, overloads pick-first" {
    try expectCodes("function f(a: number): void {} f();", &.{2554});
    try expectCodes("function f(a: number): void {} f(1, 2);", &.{2554});
    try expectClean("function f(a: number, b?: string): void {} f(1); f(1, \"x\");");
    try expectCodes("function f(a: number): void {} f(\"x\");", &.{2345});
    try expectClean("function f(...rest: number[]): void {} f(); f(1); f(1, 2, 3);");
    try expectCodes("function f(...rest: number[]): void {} f(1, \"x\");", &.{2345});
    // Overloads: first match wins.
    try expectClean(
        \\function pick(x: string): string;
        \\function pick(x: number): number;
        \\function pick(x: string | number): string | number { return x; }
        \\const s: string = pick("a");
        \\const n: number = pick(1);
    );
    try expectCodes(
        \\function pick(x: string): string;
        \\function pick(x: number): number;
        \\function pick(x: string | number): string | number { return x; }
        \\pick(true);
    , &.{2769});
    try expectCodes("declare const n: number; n();", &.{2349});
    // Negative controls for the global-`Function`-is-callable fix (see the
    // conformance fixture `calls/037_function_type_callable`): values that are
    // genuinely not callable still report TS2349.
    try expectCodes("declare const o: { a: number }; o();", &.{2349});
    try expectCodes("declare const s: string; s();", &.{2349});
}

test "generic calls: basic inference and explicit args" {
    try expectClean(
        \\function id<T>(x: T): T { return x; }
        \\const n: number = id(1);
        \\const s: string = id("a");
        \\const e: number = id<number>(2);
    );
    try expectClean(
        \\function first<T>(xs: T[]): T { return xs[0]; }
        \\const n: number = first([1, 2]);
    );
    // Literal preserved through inference; widened at let.
    try expectClean(
        \\function id<T>(x: T): T { return x; }
        \\const a: "a" = id("a");
    );
    // Contextual arrow param from generic signature.
    try expectClean(
        \\function map<T, U>(xs: T[], f: (x: T) => U): U[] {
        \\  const out: U[] = [];
        \\  let i = 0;
        \\  for (const x of xs) { out[i] = f(x); i = i + 1; }
        \\  return out;
        \\}
        \\const ns: number[] = map(["a", "bb"], (s) => s.length);
    );
    try expectCodes(
        \\function id<T>(x: T): T { return x; }
        \\id<number, string>(1);
    , &.{2558});
    // Constraint default when uninferrable.
    try expectClean(
        \\function make<T extends { a: number }>(): T | undefined { return undefined; }
        \\const r = make();
    );
}

test "classes: fields, methods, this, new, statics, implements" {
    try expectClean(
        \\class Point {
        \\  x: number;
        \\  y: number = 0;
        \\  constructor(x: number) { this.x = x; }
        \\  dist(): number { return this.x * this.x + this.y * this.y; }
        \\}
        \\const p = new Point(1);
        \\const n: number = p.dist();
    );
    try expectCodes("class C { x: number = \"nope\"; }", &.{2322});
    try expectCodes("class C { constructor(a: number) {} } new C();", &.{2554});
    try expectCodes("class C { m(): number { return 1; } } const c = new C(); c.m(\"x\");", &.{2554});
    try expectClean(
        \\class Base { a: number = 1; }
        \\class Derived extends Base { b: string = ""; }
        \\const d = new Derived();
        \\const n: number = d.a;
        \\const s: string = d.b;
    );
    try expectClean(
        \\class Counter {
        \\  static count: number = 0;
        \\  static bump(): number { return Counter.count + 1; }
        \\}
        \\const n: number = Counter.bump();
    );
    try expectCodes(
        \\interface Named { name: string; }
        \\class C implements Named { id: number = 1; }
    , &.{2420});
    try expectClean(
        \\interface Named { name: string; }
        \\class C implements Named { name: string = "c"; }
    );
    // Generic class.
    try expectClean(
        \\class Box<T> {
        \\  value: T;
        \\  constructor(v: T) { this.value = v; }
        \\  get(): T { return this.value; }
        \\}
        \\const b = new Box<number>(1);
        \\const n: number = b.get();
        \\const c = new Box("s");
        \\const s: string = c.get();
    );
}

test "interfaces: extends, merge, generics" {
    try expectClean(
        \\interface A { a: number; }
        \\interface B extends A { b: string; }
        \\declare const x: B;
        \\const n: number = x.a;
        \\const s: string = x.b;
    );
    try expectClean(
        \\interface M { a: number; }
        \\interface M { b: string; }
        \\declare const m: M;
        \\const n: number = m.a;
        \\const s: string = m.b;
    );
    try expectClean(
        \\interface Box<T> { value: T; }
        \\declare const b: Box<string>;
        \\const s: string = b.value;
    );
    try expectCodes(
        \\interface Box<T> { value: T; }
        \\declare const b: Box<string>;
        \\const n: number = b.value;
    , &.{2322});
    try expectCodes("interface Box<T> { value: T; } declare const b: Box;", &.{2314});
}

test "type aliases: generics, recursion, keyof, indexed access, typeof" {
    try expectClean(
        \\type Pair<A, B> = { first: A; second: B };
        \\declare const p: Pair<number, string>;
        \\const n: number = p.first;
        \\const s: string = p.second;
    );
    try expectClean(
        \\type Tree = { value: number; children: Tree[] };
        \\declare const t: Tree;
        \\const n: number = t.children[0].value;
    );
    try expectCodes("type T = T;", &.{2456});
    try expectClean(
        \\interface P { a: number; b: string; }
        \\declare const k: keyof P;
        \\const s: "a" | "b" = k;
    );
    try expectClean(
        \\interface P { a: number; b: string; }
        \\declare const v: P["a"];
        \\const n: number = v;
    );
    try expectClean(
        \\const origin = { x: 0, y: 0 };
        \\declare const p: typeof origin;
        \\const n: number = p.x;
    );
}

test "operators: arithmetic, plus, comparisons, 2367" {
    try expectClean("const n: number = 1 + 2 * 3; const s: string = \"a\" + 1;");
    try expectCodes("declare const o: {}; const x = o * 2;", &.{2362});
    try expectCodes("declare const o: {}; const x = 2 * o;", &.{2363});
    try expectCodes("declare const o: { a: number }; const x = o + 1;", &.{2365});
    try expectCodes("declare const s: string; declare const n: number; s < n;", &.{2365});
    try expectCodes("declare const a: string; declare const b: number; a === b;", &.{2367});
    try expectClean("declare const a: \"x\" | \"y\"; a === \"x\";");
    try expectCodes("declare const a: \"x\" | \"y\"; if (a === \"z\") {}", &.{2367});
}

test "logical operator result types" {
    try expectClean("declare const s: string; declare const n: number; const r: \"\" | number = s && n;");
    try expectClean("declare const s: string | null; const r: string = s ?? \"fallback\";");
    try expectClean("declare const s: string | undefined; const r: string = s || \"x\";");
    try expectClean("declare const b: boolean; const r: false | string = b && \"yes\";");
}

test "TDZ and use-before-assigned" {
    try expectCodes("x; let x = 1;", &.{ 2448, 2454 }); // tsc reports both
    try expectClean("function f(): number { return x; } let x = 1;");
    try expectCodes("let y: number; const z: number = y;", &.{2454});
    try expectClean("let y: number; y = 1; const z: number = y;");
    try expectClean("let y: number | undefined; const z: number | undefined = y;");
    try expectClean("declare const c: boolean; let y: number; if (c) { y = 1; } else { y = 2; } const z: number = y;");
    try expectCodes("declare const c: boolean; let y: number; if (c) { y = 1; } const z: number = y;", &.{2454});
}

test "cannot find name / wrong space / suggestions" {
    try expectCodes("missing();", &.{2304});
    try expectCodes("const x: NotAType = 1;", &.{2304});
    try expectCodes("interface I { a: number; } const x = I;", &.{2693});
    try expectCodes("const value = 1; const x: number = valeu;", &.{2552});
    try expectCodes("declare const o: { total: number }; o.totol;", &.{2551});
    try expectCodes("declare const o: { a: number }; o.b;", &.{2339});
}

/// Expect exactly one diagnostic, code `code`, whose message ends in
/// `Did you mean '<want>'?`. The conformance snapshots record only (code,
/// line), so the *text* of a suggestion has to be pinned here.
fn expectSuggestion(src: []const u8, code: u16, want: []const u8) !void {
    var t = try TestCheck.init(src);
    defer t.deinit();
    const tail = try std.fmt.allocPrint(testing.allocator, "Did you mean '{s}'?", .{want});
    defer testing.allocator.free(tail);
    if (t.result.diagnostics.len != 1 or t.result.diagnostics[0].code != code or
        !std.mem.endsWith(u8, t.result.diagnostics[0].msg, tail))
    {
        std.debug.print("--- source: {s}\n--- want TS{d} ...{s}\n--- got {d} diagnostics:\n", .{ src, code, tail, t.result.diagnostics.len });
        for (t.result.diagnostics) |dd| std.debug.print("  TS{d} {s}\n", .{ dd.code, dd.msg });
        return error.TestExpectedEqual;
    }
}

test "TS2552 suggestion: equal-distance ties break by declaration order" {
    // `fooarbaz` and `foobarbz` are each one deletion from `foobarbaz`, so they
    // tie. The pinned oracle keeps whichever is declared FIRST — swapping the
    // two declarations swaps the suggestion — because it iterates the symbol
    // table in declaration order and only replaces the incumbent on a strictly
    // smaller distance. ztsc iterates `member_atoms`, which is sorted by atom
    // id, and atom ids depend on interning order across workers: taking the
    // first tie there made the message differ from run to run. The tie-break is
    // on the binder's SymbolId, which is declaration order.
    try expectSuggestion(
        \\declare const fooarbaz: number;
        \\declare const foobarbz: number;
        \\foobarbaz;
    , 2552, "fooarbaz");
    try expectSuggestion(
        \\declare const foobarbz: number;
        \\declare const fooarbaz: number;
        \\foobarbaz;
    , 2552, "foobarbz");
}

test "TS2552 suggestion: an inner-scope candidate outranks an equally-close outer one" {
    // The outer `fooarbaz` is declared first, so a file-wide symbol-id
    // comparison would pick it; tsc's shrinking threshold cannot, because it
    // visits the innermost scope first and never replaces on a tie. The
    // tie-break is therefore scope-local.
    try expectSuggestion(
        \\declare const fooarbaz: number;
        \\function f(): void {
        \\  const foobarbz: number = 1;
        \\  foobarbaz;
        \\}
    , 2552, "foobarbz");
}

test "implicit any params (7006)" {
    try expectCodes("function f(x): void {}", &.{7006});
    try expectClean("function f(x = 3): number { return x; }");
    try expectClean("const f: (x: number) => number = (x) => x + 1;");
    try expectCodes("const f = (x) => x;", &.{7006});
}

test "noImplicitAny off: TS7006 suppressed, param still types as any" {
    const src =
        \\function f(x) { return x.anything.at.all; }
        \\const n: number = f(1);
    ;
    // Default (noImplicitAny on): the unannotated param reports TS7006.
    try expectCodes(src, &.{7006});

    // noImplicitAny off: TS7006 is suppressed. `x` still types as `any`, so the
    // deep member access is silently allowed and nothing else cascades — the
    // observable output is "today minus the diagnostic".
    var t: TestCheck = undefined;
    t.arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer t.arena.deinit();
    t.interner = Interner.init();
    defer t.interner.deinit(testing.allocator);
    const alloc = t.arena.allocator();
    const tree = try alloc.create(Ast);
    tree.* = try parser.parse(alloc, src);
    const bound = try alloc.create(Bind);
    bound.* = try binder.bind(alloc, testing.io, testing.allocator, &t.interner, tree, src, false);
    const prog = try alloc.create(modules.Program);
    prog.* = try modules.singleFileProgram(alloc, "", src, tree, bound);
    prog.no_implicit_any = false; // the effective tsconfig value
    const result = try checkFiles(alloc, testing.io, testing.allocator, &t.interner, prog, &.{0}, null, true);
    try testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "return checking: 2355 / 2366 / exhaustive switch" {
    try expectCodes("function f(): number {}", &.{2355});
    try expectCodes("declare const c: boolean; function f(): number { if (c) { return 1; } }", &.{2366});
    try expectClean("declare const c: boolean; function f(): number { if (c) { return 1; } return 2; }");
    try expectClean("function f(): void {}");
    try expectClean("function f(x: \"a\" | \"b\"): number { switch (x) { case \"a\": return 0; case \"b\": return 1; } }");
    try expectCodes("function f(x: string): number { switch (x) { case \"a\": return 0; } }", &.{2366});
    try expectClean("function f(): number { while (true) {} }");
}

test "const assignment / readonly (2588 / 2540)" {
    try expectCodes("const x = 1; x = 2;", &.{2588});
    try expectCodes("interface P { readonly a: number; } declare const p: P; p.a = 2;", &.{2540});
    try expectClean("interface P { readonly a: number; } declare const p: P; const n: number = p.a;");
}

test "for-of: arrays, tuples, strings; bad iterables" {
    try expectClean("for (const n of [1, 2, 3]) { const x: number = n; }");
    try expectClean("declare const t: [number, string]; for (const v of t) { const x: number | string = v; }");
    try expectClean("declare const s: string; for (const ch of s) { const c: string = ch; }");
    try expectCodes("for (const x of 42) {}", &.{2488});
}

test "switch comparability (2678)" {
    try expectCodes("declare const n: number; switch (n) { case \"a\": break; }", &.{2678});
    try expectClean("declare const n: number; switch (n) { case 1: break; default: break; }");
}

test "as-casts (2352)" {
    try expectClean("declare const u: unknown; const n = u as number;");
    try expectClean("declare const n: number | string; const m = n as number;");
    try expectCodes("declare const s: string; const n = s as number;", &.{2352});
    try expectClean("declare const s: string; const n = s as unknown as number;");
    // Cast to/from an unconstrained type parameter overlaps anything.
    try expectClean("function f<T>(x: { a: number }): T { return x as T; }");
    try expectClean("function f<T>(x: T): { a: number } { return x as { a: number }; }");
    // Union target: overlaps via one constituent; rejects when none overlap.
    try expectClean("declare const o: { name: string }; const p = o as ({ name: string; id: number } | null);");
    try expectCodes("declare const o: { q: number }; const n = o as (number | boolean);", &.{2352});
    // A constrained type parameter still rejects a non-overlapping cast.
    try expectCodes("function f<T extends { a: number }>(x: T): { b: string } { return x as { b: string }; }", &.{2352});
}

test "printer goldens via diagnostics" {
    var t = try TestCheck.init("const x: { a: number; b?: string } = 1;");
    defer t.deinit();
    try testing.expectEqual(@as(usize, 1), t.result.diagnostics.len);
    try testing.expectEqualStrings("Type '1' is not assignable to type '{ a: number; b?: string; }'.", t.result.diagnostics[0].msg);

    var t2 = try TestCheck.init("declare function f(cb: (x: number) => string): void; f(3);");
    defer t2.deinit();
    try testing.expectEqual(@as(usize, 1), t2.result.diagnostics.len);
    try testing.expectEqualStrings("Argument of type '3' is not assignable to parameter of type '(x: number) => string'.", t2.result.diagnostics[0].msg);

    var t3 = try TestCheck.init("const x: [number, string] | null = true;");
    defer t3.deinit();
    try testing.expectEqual(@as(usize, 1), t3.result.diagnostics.len);
    try testing.expectEqualStrings("Type 'true' is not assignable to type '[number, string] | null'.", t3.result.diagnostics[0].msg);

    // `&` binds tighter than `|`, so a union *inside* an intersection needs
    // parens — `(B | C) & A`, not `B | C & A`, which reads as `B | (C & A)`.
    // `makeIntersection` distributes a union constituent, so the only way to
    // hold one is to overflow the cross-product cap (6 unions of 8 members =
    // 8^6 = 262144 > 100000), which keeps the intersection undistributed.
    const wide =
        "type U1 = { a1: 1 } | { a2: 1 } | { a3: 1 } | { a4: 1 } | { a5: 1 } | { a6: 1 } | { a7: 1 } | { a8: 1 };\n" ++
        "type U2 = { b1: 1 } | { b2: 1 } | { b3: 1 } | { b4: 1 } | { b5: 1 } | { b6: 1 } | { b7: 1 } | { b8: 1 };\n" ++
        "type U3 = { c1: 1 } | { c2: 1 } | { c3: 1 } | { c4: 1 } | { c5: 1 } | { c6: 1 } | { c7: 1 } | { c8: 1 };\n" ++
        "type U4 = { d1: 1 } | { d2: 1 } | { d3: 1 } | { d4: 1 } | { d5: 1 } | { d6: 1 } | { d7: 1 } | { d8: 1 };\n" ++
        "type U5 = { e1: 1 } | { e2: 1 } | { e3: 1 } | { e4: 1 } | { e5: 1 } | { e6: 1 } | { e7: 1 } | { e8: 1 };\n" ++
        "type U6 = { f1: 1 } | { f2: 1 } | { f3: 1 } | { f4: 1 } | { f5: 1 } | { f6: 1 } | { f7: 1 } | { f8: 1 };\n" ++
        "declare const x: U1 & U2 & U3 & U4 & U5 & U6;\n" ++
        "const bad: string = x;\n";
    var t4 = try TestCheck.init(wide);
    defer t4.deinit();
    try testing.expectEqual(@as(usize, 1), t4.result.diagnostics.len);
    try testing.expect(std.mem.startsWith(u8, t4.result.diagnostics[0].msg, "Type '({ a1: 1; } | "));
    try testing.expect(std.mem.indexOf(u8, t4.result.diagnostics[0].msg, "{ a8: 1; }) & ({ b1: 1; }") != null);
}

test "stress: checker total on random and token soup" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var interner = Interner.init();
    defer interner.deinit(testing.allocator);
    var prng = std.Random.DefaultPrng.init(0xc4ec_2026);
    const random = prng.random();

    const vocab = [_][]const u8{
        "if",        "else",   "function", "class",      "const",  "let",    "var",     "interface",
        "type",      "of",     "in",       "for",        "while",  "switch", "case",    "return",
        "new",       "typeof", "extends",  "implements", "x",      "y",      "Foo",     "42",
        "\"s\"",     "{",      "}",        "(",          ")",      "[",      "]",       ";",
        ",",         ":",      "?",        ".",          "=>",     "=",      "+",       "-",
        "===",       "!==",    "&&",       "||",         "??",     "!",      "|",       "&",
        "<",         ">",      "keyof",    "readonly",   "number", "string", "boolean", "null",
        "undefined", "never",  "unknown",  "any",        "true",   "false",  "...",     "?.",
    };

    var buf: [1024]u8 = undefined;
    for (0..150) |round| {
        var len: usize = 0;
        if (round % 2 == 0) {
            len = random.uintLessThan(usize, 256);
            random.bytes(buf[0..len]);
        } else {
            const count = random.uintLessThan(usize, 80);
            for (0..count) |_| {
                const word = vocab[random.uintLessThan(usize, vocab.len)];
                if (len + word.len + 1 > buf.len) break;
                @memcpy(buf[len..][0..word.len], word);
                len += word.len;
                buf[len] = if (random.uintLessThan(u8, 8) == 0) '\n' else ' ';
                len += 1;
            }
        }
        const alloc = arena.allocator();
        const tree = try alloc.create(Ast);
        tree.* = parser.parse(alloc, buf[0..len]) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.SourceTooLarge => unreachable,
        };
        const bound = try alloc.create(Bind);
        bound.* = try binder.bind(alloc, testing.io, testing.allocator, &interner, tree, buf[0..len], false);
        const result = try check(alloc, testing.io, testing.allocator, &interner, tree, bound, buf[0..len]);
        for (result.diagnostics) |dd| {
            try testing.expect(dd.span.start <= len + 1);
            try testing.expect(dd.code != 0);
        }
        _ = arena.reset(.retain_capacity);
    }
}

fn fuzzCheckerOne(_: void, smith: *std.testing.Smith) !void {
    var source_buf: [400]u8 = undefined;
    const len = smith.sliceWeightedBytes(&source_buf, &.{
        .rangeAtMost(u8, 0x00, 0xff, 1),
        .rangeAtMost(u8, 0x20, 0x7e, 8),
        .value(u8, '{', 3),
        .value(u8, '}', 3),
        .value(u8, ':', 3),
        .value(u8, '=', 3),
        .value(u8, ';', 3),
        .value(u8, '|', 2),
        .value(u8, '\n', 3),
    });
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var interner = Interner.init();
    defer interner.deinit(testing.allocator);
    const alloc = arena.allocator();
    const tree = try alloc.create(Ast);
    tree.* = parser.parse(alloc, source_buf[0..len]) catch return;
    const bound = try alloc.create(Bind);
    bound.* = try binder.bind(alloc, testing.io, testing.allocator, &interner, tree, source_buf[0..len], false);
    _ = try check(alloc, testing.io, testing.allocator, &interner, tree, bound, source_buf[0..len]);
}

test "fuzz: checker on arbitrary bytes" {
    try testing.fuzz({}, fuzzCheckerOne, .{});
}

test "assignability matrix: intrinsics x intrinsics (table test)" {
    // Row = source, column = target. 1 = assignable under strict rules.
    const names = [_][]const u8{ "any", "unknown", "never", "void", "undefined", "null", "string", "number", "boolean", "bigint" };
    // Rows in the same order; targets across.
    const table = [10][10]u1{
        // to:  any un nv vo ud nl st nu bo bi     from:
        .{ 1, 1, 0, 1, 1, 1, 1, 1, 1, 1 }, // any (assignable to all but never)
        .{ 1, 1, 0, 0, 0, 0, 0, 0, 0, 0 }, // unknown
        .{ 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 }, // never
        .{ 1, 1, 0, 1, 0, 0, 0, 0, 0, 0 }, // void
        .{ 1, 1, 0, 1, 1, 0, 0, 0, 0, 0 }, // undefined
        .{ 1, 1, 0, 0, 0, 1, 0, 0, 0, 0 }, // null
        .{ 1, 1, 0, 0, 0, 0, 1, 0, 0, 0 }, // string
        .{ 1, 1, 0, 0, 0, 0, 0, 1, 0, 0 }, // number
        .{ 1, 1, 0, 0, 0, 0, 0, 0, 1, 0 }, // boolean
        .{ 1, 1, 0, 0, 0, 0, 0, 0, 0, 1 }, // bigint
    };
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var expected_errors: usize = 0;
    const w = &aw.writer;
    for (names, 0..) |n, i| w.print("declare const s{d}: {s};\n", .{ i, n }) catch return error.OutOfMemory;
    for (names, 0..) |sname, i| {
        _ = sname;
        for (names, 0..) |tname, j| {
            w.print("const t{d}_{d}: {s} = s{d};\n", .{ i, j, tname, i }) catch return error.OutOfMemory;
            if (table[i][j] == 0) expected_errors += 1;
        }
    }
    var t = try TestCheck.init(aw.written());
    defer t.deinit();
    var got_2322: usize = 0;
    for (t.result.diagnostics) |d| {
        if (d.code == 2322) got_2322 += 1 else return error.TestUnexpectedResult;
    }
    try testing.expectEqual(expected_errors, got_2322);
}

// ---------------------------------------------------------------------------
// error elaboration chains (checker/elaborate.zig)
//
// The conformance snapshots pin (code, line) only, so the chain TEXT needs its
// own oracle. Every string below was copied verbatim from tsgo 7.0.2 run on the
// same source (`--strict --noEmit --pretty false`); nothing here was invented.
// Where ztsc's TYPE PRINTER still differs from tsgo (unquoted non-identifier
// property names, `[x: string]` for a declared `[k: string]`, an optional
// property printed without `| undefined`, the `new () => T` and method
// shorthands) only the chain is asserted, via `expectChain` — those are
// separate, pre-existing divergences on the headline that this feature does
// not touch.
// ---------------------------------------------------------------------------

/// The whole message of the single diagnostic `src` must produce.
fn expectMsg(src: []const u8, expected: []const u8) !void {
    var t = try TestCheck.init(src);
    defer t.deinit();
    if (t.result.diagnostics.len != 1) {
        std.debug.print("--- source: {s}\n--- got {d} diagnostics:\n", .{ src, t.result.diagnostics.len });
        for (t.result.diagnostics) |dd| std.debug.print("  TS{d} {s}\n", .{ dd.code, dd.msg });
        return error.TestExpectedEqual;
    }
    try testing.expectEqualStrings(expected, t.result.diagnostics[0].msg);
}

/// Everything below the headline: the elaboration chain alone.
fn expectChain(src: []const u8, expected: []const u8) !void {
    var t = try TestCheck.init(src);
    defer t.deinit();
    if (t.result.diagnostics.len != 1) {
        std.debug.print("--- source: {s}\n--- got {d} diagnostics:\n", .{ src, t.result.diagnostics.len });
        for (t.result.diagnostics) |dd| std.debug.print("  TS{d} {s}\n", .{ dd.code, dd.msg });
        return error.TestExpectedEqual;
    }
    const msg = t.result.diagnostics[0].msg;
    const nl = std.mem.indexOfScalar(u8, msg, '\n') orelse {
        std.debug.print("--- source: {s}\n--- no chain in: {s}\n", .{ src, msg });
        return error.TestExpectedEqual;
    };
    try testing.expectEqualStrings(expected, msg[nl + 1 ..]);
}

/// The diagnostic must carry NO chain (a bare one-line message).
fn expectNoChain(src: []const u8) !void {
    var t = try TestCheck.init(src);
    defer t.deinit();
    for (t.result.diagnostics) |d| {
        if (std.mem.indexOfScalar(u8, d.msg, '\n') != null) {
            std.debug.print("--- source: {s}\n--- unexpected chain: {s}\n", .{ src, d.msg });
            return error.TestExpectedEqual;
        }
    }
}

test "elaboration: one property level keeps tsc's singular phrasing" {
    try expectMsg(
        \\declare const s: { a: number };
        \\const t: { a: string } = s;
    ,
        \\Type '{ a: number; }' is not assignable to type '{ a: string; }'.
        \\  Types of property 'a' are incompatible.
        \\    Type 'number' is not assignable to type 'string'.
    );
}

test "elaboration: nested properties collapse into a dotted path" {
    try expectMsg(
        \\declare const s: { a: { b: number } };
        \\const t: { a: { b: string } } = s;
    ,
        \\Type '{ a: { b: number; }; }' is not assignable to type '{ a: { b: string; }; }'.
        \\  The types of 'a.b' are incompatible between these types.
        \\    Type 'number' is not assignable to type 'string'.
    );
    try expectMsg(
        \\declare const s: { a: { b: { c: number } } };
        \\const t: { a: { b: { c: string } } } = s;
    ,
        \\Type '{ a: { b: { c: number; }; }; }' is not assignable to type '{ a: { b: { c: string; }; }; }'.
        \\  The types of 'a.b.c' are incompatible between these types.
        \\    Type 'number' is not assignable to type 'string'.
    );
}

test "elaboration: a non-identifier path segment is bracketed and quoted" {
    try expectChain(
        \\declare const s: { a: { "c-d": number } };
        \\const t: { a: { "c-d": string } } = s;
    ,
        \\  The types of 'a["c-d"]' are incompatible between these types.
        \\    Type 'number' is not assignable to type 'string'.
    );
    // A numeric name stays bare (tsgo brackets only what its symbol printer
    // quotes, and it does not quote numbers).
    try expectMsg(
        \\declare const s: { a: { 0: number } };
        \\const t: { a: { 0: string } } = s;
    ,
        \\Type '{ a: { 0: number; }; }' is not assignable to type '{ a: { 0: string; }; }'.
        \\  The types of 'a.0' are incompatible between these types.
        \\    Type 'number' is not assignable to type 'string'.
    );
}

test "elaboration: parameters report contravariantly with both names" {
    try expectMsg(
        \\declare const f: (foo: number) => void;
        \\const g: (bar: string) => void = f;
    ,
        \\Type '(foo: number) => void' is not assignable to type '(bar: string) => void'.
        \\  Types of parameters 'foo' and 'bar' are incompatible.
        \\    Type 'string' is not assignable to type 'number'.
    );
    try expectMsg(
        \\declare const f: { go: (x: number) => void };
        \\const g: { go: (x: string) => void } = f;
    ,
        \\Type '{ go: (x: number) => void; }' is not assignable to type '{ go: (x: string) => void; }'.
        \\  Types of property 'go' are incompatible.
        \\    Type '(x: number) => void' is not assignable to type '(x: string) => void'.
        \\      Types of parameters 'x' and 'x' are incompatible.
        \\        Type 'string' is not assignable to type 'number'.
    );
}

test "elaboration: return types render as a call in the path" {
    try expectMsg(
        \\declare const f: { go: () => number };
        \\const g: { go: () => string } = f;
    ,
        \\Type '{ go: () => number; }' is not assignable to type '{ go: () => string; }'.
        \\  The types returned by 'go()' are incompatible between these types.
        \\    Type 'number' is not assignable to type 'string'.
    );
    // With parameters the call prints as `(...)`.
    try expectMsg(
        \\declare const f: { go: (a: number, b: number) => number };
        \\const g: { go: (a: number, b: number) => string } = f;
    ,
        \\Type '{ go: (a: number, b: number) => number; }' is not assignable to type '{ go: (a: number, b: number) => string; }'.
        \\  The types returned by 'go(...)' are incompatible between these types.
        \\    Type 'number' is not assignable to type 'string'.
    );
    // A call that is not the FIRST segment keeps the "The types of" headline.
    try expectMsg(
        \\declare const f: { a: { b: () => number } };
        \\const g: { a: { b: () => string } } = f;
    ,
        \\Type '{ a: { b: () => number; }; }' is not assignable to type '{ a: { b: () => string; }; }'.
        \\  The types of 'a.b()' are incompatible between these types.
        \\    Type 'number' is not assignable to type 'string'.
    );
    // ... and properties continue past the call.
    try expectMsg(
        \\declare const f: { go: () => { b: { c: number } } };
        \\const g: { go: () => { b: { c: string } } } = f;
    ,
        \\Type '{ go: () => { b: { c: number; }; }; }' is not assignable to type '{ go: () => { b: { c: string; }; }; }'.
        \\  The types returned by 'go().b.c' are incompatible between these types.
        \\    Type 'number' is not assignable to type 'string'.
    );
}

test "elaboration: a lone return message is elided, as tsc marks it" {
    try expectMsg(
        \\declare const f: () => number;
        \\const g: () => string = f;
    ,
        \\Type '() => number' is not assignable to type '() => string'.
        \\  Type 'number' is not assignable to type 'string'.
    );
    // A run may not open with a return, so the outer return closes at once
    // and the properties below it form their own path.
    try expectMsg(
        \\declare const f: () => { b: { c: number } };
        \\const g: () => { b: { c: string } } = f;
    ,
        \\Type '() => { b: { c: number; }; }' is not assignable to type '() => { b: { c: string; }; }'.
        \\  Type '{ b: { c: number; }; }' is not assignable to type '{ b: { c: string; }; }'.
        \\    The types of 'b.c' are incompatible between these types.
        \\      Type 'number' is not assignable to type 'string'.
    );
    // Nor may a return follow a return.
    try expectMsg(
        \\declare const f: { go: () => () => number };
        \\const g: { go: () => () => string } = f;
    ,
        \\Type '{ go: () => () => number; }' is not assignable to type '{ go: () => () => string; }'.
        \\  The types returned by 'go()' are incompatible between these types.
        \\    Type '() => number' is not assignable to type '() => string'.
        \\      Type 'number' is not assignable to type 'string'.
    );
}

test "elaboration: construct signatures wrap the path in a `new` call" {
    try expectChain(
        \\declare const c: { mk: { new (): { b: number } } };
        \\const d: { mk: { new (): { b: string } } } = c;
    ,
        \\  The types returned by '(new mk()).b' are incompatible between these types.
        \\    Type 'number' is not assignable to type 'string'.
    );
    try expectChain(
        \\declare const c: { mk: { new (q: number): { b: number } } };
        \\const d: { mk: { new (q: number): { b: string } } } = c;
    ,
        \\  The types returned by '(new mk(...)).b' are incompatible between these types.
        \\    Type 'number' is not assignable to type 'string'.
    );
}

test "elaboration: element, union, intersection and type-argument boundaries" {
    // Array element: a full relation line, no path.
    try expectMsg(
        \\declare const s: { b: number }[];
        \\const t: { b: string }[] = s;
    ,
        \\Type '{ b: number; }[]' is not assignable to type '{ b: string; }[]'.
        \\  Type '{ b: number; }' is not assignable to type '{ b: string; }'.
        \\    Types of property 'b' are incompatible.
        \\      Type 'number' is not assignable to type 'string'.
    );
    // Union source: the failing constituent against the whole target.
    try expectMsg(
        \\declare const s: { a: number | boolean };
        \\const t: { a: string | number } = s;
    ,
        \\Type '{ a: number | boolean; }' is not assignable to type '{ a: string | number; }'.
        \\  Types of property 'a' are incompatible.
        \\    Type 'number | boolean' is not assignable to type 'string | number'.
        \\      Type 'boolean' is not assignable to type 'string | number'.
    );
    // Union target: the best-matching constituent, by shared property names.
    try expectMsg(
        \\declare const s: { a: number };
        \\const t: { a: string } | { c: number } = s;
    ,
        \\Type '{ a: number; }' is not assignable to type '{ a: string; } | { c: number; }'.
        \\  Type '{ a: number; }' is not assignable to type '{ a: string; }'.
        \\    Types of property 'a' are incompatible.
        \\      Type 'number' is not assignable to type 'string'.
    );
    // Intersection target: the failing member.
    try expectMsg(
        \\declare const s: { a: number };
        \\const t: { a: string } & { c: number } = s;
    ,
        \\Type '{ a: number; }' is not assignable to type '{ a: string; } & { c: number; }'.
        \\  Type '{ a: number; }' is not assignable to type '{ a: string; }'.
        \\    Types of property 'a' are incompatible.
        \\      Type 'number' is not assignable to type 'string'.
    );
    // Two references to one generic relate by their ARGUMENTS.
    try expectMsg(
        \\interface Box<T> { v: T }
        \\declare const s: Box<number>;
        \\const t: Box<string> = s;
    ,
        \\Type 'Box<number>' is not assignable to type 'Box<string>'.
        \\  Type 'number' is not assignable to type 'string'.
    );
}

test "elaboration: tuple positions, tuple arity and index signatures" {
    try expectMsg(
        \\declare const s: [number, string];
        \\const t: [string, string] = s;
    ,
        \\Type '[number, string]' is not assignable to type '[string, string]'.
        \\  Type at position 0 in source is not compatible with type at position 0 in target.
        \\    Type 'number' is not assignable to type 'string'.
    );
    // Arity prints BELOW the level's own relation line (tsc does not suppress
    // that one, unlike the missing-property message).
    try expectMsg(
        \\declare const s: { a: [number] };
        \\const t: { a: [number, string] } = s;
    ,
        \\Type '{ a: [number]; }' is not assignable to type '{ a: [number, string]; }'.
        \\  Types of property 'a' are incompatible.
        \\    Type '[number]' is not assignable to type '[number, string]'.
        \\      Source has 1 element(s) but target requires 2.
    );
    try expectChain(
        \\declare const s: { [k: string]: number };
        \\const t: { [k: string]: string } = s;
    ,
        \\  'string' index signatures are incompatible.
        \\    Type 'number' is not assignable to type 'string'.
    );
    try expectChain(
        \\declare const s: { [k: number]: number };
        \\const t: { [k: number]: string } = s;
    ,
        \\  'number' index signatures are incompatible.
        \\    Type 'number' is not assignable to type 'string'.
    );
}

test "elaboration: a missing property REPLACES the level's relation line" {
    try expectMsg(
        \\declare const s: { a: { x: number } };
        \\const t: { a: { x: number; y: string } } = s;
    ,
        \\Type '{ a: { x: number; }; }' is not assignable to type '{ a: { x: number; y: string; }; }'.
        \\  Types of property 'a' are incompatible.
        \\    Property 'y' is missing in type '{ x: number; }' but required in type '{ x: number; y: string; }'.
    );
    try expectMsg(
        \\declare const s: { a: { x: number } };
        \\const t: { a: { x: number; y: string; z: boolean } } = s;
    ,
        \\Type '{ a: { x: number; }; }' is not assignable to type '{ a: { x: number; y: string; z: boolean; }; }'.
        \\  Types of property 'a' are incompatible.
        \\    Type '{ x: number; }' is missing the following properties from type '{ x: number; y: string; z: boolean; }': y, z
    );
    try expectMsg(
        \\declare const s: { a: { b: { x: number } } };
        \\const t: { a: { b: { x: number; y: string } } } = s;
    ,
        \\Type '{ a: { b: { x: number; }; }; }' is not assignable to type '{ a: { b: { x: number; y: string; }; }; }'.
        \\  The types of 'a.b' are incompatible between these types.
        \\    Property 'y' is missing in type '{ x: number; }' but required in type '{ x: number; y: string; }'.
    );
}

test "elaboration: past five names the missing list abbreviates (TS2740)" {
    // Both the headline and the chain render the list through one formatter,
    // so they abbreviate together — and tsc's code changes with it.
    try expectMsg(
        \\declare const s: { p: number };
        \\const t: { p: number; q1: 1; q2: 1; q3: 1; q4: 1; q5: 1; q6: 1 } = s;
    ,
        \\Type '{ p: number; }' is missing the following properties from type '{ p: number; q1: 1; q2: 1; q3: 1; q4: 1; q5: 1; q6: 1; }': q1, q2, q3, q4, and 2 more.
    );
    try expectCodes(
        \\declare const s: { p: number };
        \\const t: { p: number; q1: 1; q2: 1; q3: 1; q4: 1; q5: 1; q6: 1 } = s;
    , &.{2740});
    // Exactly five still lists them all, under TS2739.
    try expectCodes(
        \\declare const s: { p: number };
        \\const t: { p: number; q1: 1; q2: 1; q3: 1; q4: 1; q5: 1 } = s;
    , &.{2739});
    try expectChain(
        \\declare const s: { a: { p: number } };
        \\const t: { a: { p: number; q1: 1; q2: 1; q3: 1; q4: 1; q5: 1; q6: 1 } } = s;
    ,
        \\  Types of property 'a' are incompatible.
        \\    Type '{ p: number; }' is missing the following properties from type '{ p: number; q1: 1; q2: 1; q3: 1; q4: 1; q5: 1; q6: 1; }': q1, q2, q3, q4, and 2 more.
    );
}

test "elaboration: TS2345 argument mismatches chain the same way" {
    try expectMsg(
        \\declare function take(p: { a: { b: string } }): void;
        \\declare const arg: { a: { b: number } };
        \\take(arg);
    ,
        \\Argument of type '{ a: { b: number; }; }' is not assignable to parameter of type '{ a: { b: string; }; }'.
        \\  The types of 'a.b' are incompatible between these types.
        \\    Type 'number' is not assignable to type 'string'.
    );
}

test "elaboration: TS2344 constraint violations chain under their own head" {
    try expectMsg(
        \\interface Exact { s: string }
        \\interface ExactHolder<T extends Exact> { v: T }
        \\declare const h: ExactHolder<{ s: number }>;
    ,
        \\Type '{ s: number; }' does not satisfy the constraint 'Exact'.
        \\  Types of property 's' are incompatible.
        \\    Type 'number' is not assignable to type 'string'.
    );
    try expectMsg(
        \\interface Deep { a: { b: string } }
        \\interface DeepHolder<T extends Deep> { v: T }
        \\declare const h: DeepHolder<{ a: { b: number } }>;
    ,
        \\Type '{ a: { b: number; }; }' does not satisfy the constraint 'Deep'.
        \\  The types of 'a.b' are incompatible between these types.
        \\    Type 'number' is not assignable to type 'string'.
    );
    // The missing-property head still wins over the constraint head, and it
    // abbreviates past five names exactly as the assignment head does.
    try expectMsg(
        \\interface Wide { p: number; q1: 1; q2: 1; q3: 1; q4: 1; q5: 1; q6: 1 }
        \\interface WideHolder<T extends Wide> { v: T }
        \\declare const h: WideHolder<{ p: number }>;
    ,
        \\Type '{ p: number; }' is missing the following properties from type 'Wide': q1, q2, q3, q4, and 2 more.
    );
}

test "elaboration: nothing to derive leaves the headline alone" {
    // Primitive leaves, a top-level missing property (already TS2741), a
    // did-you-mean morph, and a source the walk cannot descend into.
    try expectNoChain("const a: string = 1;");
    try expectNoChain(
        \\interface P { x: number; y: number }
        \\declare const p: { x: number };
        \\const q: P = p;
    );
    try expectNoChain(
        \\declare const s: "aa";
        \\const t: "ab" | "ac" = s;
    );
    try expectNoChain("declare const s: { a: number }; const t: number = s;");
    // A union SOURCE does chain, down to the constituent that fails.
    try expectMsg(
        \\declare const u: string | number;
        \\const s: string = u;
    ,
        \\Type 'string | number' is not assignable to type 'string'.
        \\  Type 'number' is not assignable to type 'string'.
    );
}

test "elaboration: a recursive pair terminates" {
    // The walk would descend onto the same pair forever without the cycle
    // guard; the point is that this returns at all.
    try expectCodes(
        \\interface A { n: A; v: number }
        \\interface B { n: B; v: string }
        \\declare const a: A;
        \\const b: B = a;
    , &.{2322});
}
