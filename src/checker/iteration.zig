//! The iteration and async protocols: `Promise`/`Awaited`, the
//! `[Symbol.iterator]()` / `[Symbol.asyncIterator]()` walks, and the lib
//! iterator interfaces both of them resolve through.
//!
//! One concern, previously split down the middle: `for..of`/spread asked
//! `stmts.zig` for an element type, `await`/`yield` asked `props.zig` for a
//! promise payload, and the two halves called into each other on every
//! `for await` and every async generator.

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const intern = @import("../intern.zig");
const types = @import("../types.zig");

const Atom = intern.Atom;
const Node = ast.Node;
const TypeId = types.TypeId;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;

// =====================================================================
// promises, `await`, and generator yield types
// =====================================================================

/// Wrap `payload` in the global `Promise<T>`. Falls back to `any`
/// when the lib has no `Promise` interface (e.g. `--noLib`).
pub fn makePromise(c: *Checker, payload: TypeId) Error!TypeId {
    const sym = c.prog.globals.lookup(c.atom_Promise) orelse return types.any_type;
    if (!c.symFlags(sym).interface) return types.any_type;
    return c.ts.makeRef(sym, &.{payload});
}

/// Whether `t` is a `.ref` to `Promise`/`PromiseLike` whose first type
/// argument is exactly the type parameter `tp_sym` (the `PromiseLike<T>`
/// member of a `.then` onfulfilled return `T | PromiseLike<T>`).
pub fn isPromiseLikeOf(c: *Checker, t: TypeId, tp_sym: u32) bool {
    if (c.ts.kind(t) != .ref) return false;
    const sym = c.ts.refSymbol(t);
    const p = c.prog.globals.lookup(c.atom_Promise);
    const pl = c.prog.globals.lookup(c.atom_PromiseLike);
    if ((p == null or sym != p.?) and (pl == null or sym != pl.?)) return false;
    const args = c.ts.refArgs(t);
    if (args.len == 0) return false;
    return c.ts.kind(args[0]) == .type_param and c.ts.typeParamSymbol(args[0]) == tp_sym;
}

/// `Awaited<T>`: unwrap a `Promise<T>` / `PromiseLike<T>` to `T`, to a
/// fixed point; any other type passes through (await on a non-thenable
/// yields the value itself).
///
/// The lib types both of them (`Promise<T> extends PromiseLike<T>`, and
/// `then` returns `PromiseLike<TResult>`), so a bare `PromiseLike<T>`
/// receiver is ordinary — `await pool.all()` on a `PromiseLike<unknown[]>`
/// is `unknown[]`, not `PromiseLike<unknown[]>`. tsc's `Awaited<T>` is
/// structural over *any* thenable and recursive; ztsc recognizes the two
/// lib names and recurses, which covers every nesting of them
/// (`Promise<PromiseLike<T>>`, `PromiseLike<Promise<T>>`, …). A
/// hand-written thenable that is neither is still a gap (under-report:
/// the value keeps its object type).
pub fn awaitedType(c: *Checker, t: TypeId) Error!TypeId {
    return awaitedTypeRec(c, t, 0);
}

fn awaitedTypeRec(c: *Checker, t: TypeId, depth: u32) Error!TypeId {
    // A self-referential alias (`type P = Promise<P>`) would spin; the cap
    // is far above any real nesting and only ever leaves the type unwrapped.
    if (depth >= 16) return t;
    // `Awaited<T>` distributes over unions: `await (Promise<X> | undefined)`
    // is `X | undefined` (tsc). Without this, a `Promise<X> | undefined`
    // receiver — common now that optional chains yield `... | undefined` —
    // fails to unwrap and surfaces spurious property/callable errors.
    if (c.ts.kind(t) == .union_type) {
        var parts: std.ArrayList(TypeId) = .empty;
        defer parts.deinit(c.scratch());
        for (try c.memberList(t)) |m| try parts.append(c.scratch(), try awaitedTypeRec(c, m, depth + 1));
        return c.ts.makeUnion(c.scratch(), parts.items);
    }
    // An INTERSECTION awaits through its thenable constituent. tsc reads
    // the awaited type off the `then` member (`getPromisedTypeOfPromise`),
    // and in `Promise<T> & { resolve; reject }` — the promise-with-
    // resolvers shape — `then` comes from the promise half, so the result
    // is `T`. Returning the whole intersection instead made every read off
    // an awaited resolvable promise report TS2339.
    if (c.ts.kind(t) == .intersection) {
        for (try c.memberList(t)) |m| {
            const a = try c.awaitedType(m);
            if (a != m) return a;
        }
        return t;
    }
    if (c.ts.kind(t) == .ref) {
        const sym = c.ts.refSymbol(t);
        const p = c.prog.globals.lookup(c.atom_Promise);
        const pl = c.prog.globals.lookup(c.atom_PromiseLike);
        if ((p != null and sym == p.?) or (pl != null and sym == pl.?)) {
            const args = c.ts.refArgs(t);
            if (args.len >= 1) return awaitedTypeRec(c, args[0], depth + 1);
        }
    }
    return t;
}

/// If `t` is a ref to one of the lib's iterator interfaces whose first
/// type arg is the yield element (`Generator<T>`/`Iterator<T>`/
/// `IterableIterator<T>`, plus the TS ≥5.6 `IteratorObject<T>` and the
/// named built-in iterators like `MapIterator<T>`), return that `T`;
/// otherwise 0.
pub fn generatorYieldType(c: *Checker, t: TypeId) TypeId {
    if (c.ts.kind(t) != .ref) return 0;
    const sym = c.ts.refSymbol(t);
    const names = [_]Atom{
        c.atom_Generator,      c.atom_Iterator,       c.atom_IterableIterator,
        c.atom_IteratorObject, c.atom_ArrayIterator,  c.atom_MapIterator,
        c.atom_SetIterator,    c.atom_StringIterator, c.atom_RegExpStringIterator,
    };
    for (names) |name| {
        const g = c.prog.globals.lookup(name) orelse continue;
        if (sym == g) {
            const args = c.ts.refArgs(t);
            if (args.len >= 1) return args[0];
            return 0;
        }
    }
    return 0;
}

/// Async analogue of `generatorYieldType`: the first type arg of a lib
/// async-iterator ref (`AsyncGenerator<T>`/`AsyncIterator<T>`/
/// `AsyncIterableIterator<T>`/`AsyncIteratorObject<T>`), else 0.
pub fn asyncGeneratorYieldType(c: *Checker, t: TypeId) TypeId {
    if (c.ts.kind(t) != .ref) return 0;
    const sym = c.ts.refSymbol(t);
    const names = [_]Atom{
        c.atom_AsyncGenerator,        c.atom_AsyncIterator,
        c.atom_AsyncIterableIterator, c.atom_AsyncIteratorObject,
    };
    for (names) |name| {
        const g = c.prog.globals.lookup(name) orelse continue;
        if (sym == g) {
            const args = c.ts.refArgs(t);
            if (args.len >= 1) return args[0];
            return 0;
        }
    }
    return 0;
}

/// The yield, return and next types a generator's return type carries —
/// `Generator<Y, R, N>`'s three arguments. `ret`/`next` are `types.no_type`
/// when the spelling left them off.
pub const IterationCtx = struct { yield: TypeId, ret: TypeId, next: TypeId };

/// The yield, return and next contexts a generator takes from a CONTEXTUAL
/// return type — tsc's `getContextualIterationType`, which reads
/// `getIterationTypeOfGeneratorFunctionReturnType` off the contextual
/// signature's return type. Null when that type names no generator.
///
/// The contextual type is routinely a UNION with the generator as one arm
/// (`() => number | Generator<(arg: number) => void, any, void>` —
/// `contextualTypeOnYield1`), so the first arm that names one wins; tsc reaches
/// the same place through `getIterationTypesOfType` over the union.
///
/// Purely contextual: every half only TYPES the operands (or, for `next`,
/// spells the third argument of the INFERRED `Generator<…>`), and nothing is
/// reported against any of them — see `FnCtx.yield_ctx`.
pub fn contextualIteration(c: *Checker, ctx: TypeId, is_async: bool) Error!?IterationCtx {
    if (ctx == 0 or ctx == types.no_type) return null;
    if (c.ts.kind(ctx) == .union_type) {
        for (try c.memberList(ctx)) |m| {
            if (try contextualIteration(c, m, is_async)) |it| return it;
        }
        return null;
    }
    const y = if (is_async) c.asyncGeneratorYieldType(ctx) else c.generatorYieldType(ctx);
    if (y == 0) {
        // `Iterable<T, TReturn, TNext>` / `AsyncIterable<…>` are legal
        // generator return types too, and `generatorYieldType` — whose job is
        // the CHECK target — leaves them out because a written `Iterable`
        // annotation is not what tsc relates a `yield` to. As a CONTEXT it is:
        // `function* (): Iterator<Iterable<(x: string) => number>>` types the
        // inner generator of `yield (function*(){…})()` through it.
        if (c.ts.kind(ctx) != .ref) return null;
        const sym = c.ts.refSymbol(ctx);
        const name = try c.atom(if (is_async) "AsyncIterable" else "Iterable");
        const g = c.prog.globals.lookup(name) orelse return null;
        if (sym != g) return null;
        return iterationCtxOf(c.ts.refArgs(ctx));
    }
    return iterationCtxOf(c.ts.refArgs(ctx));
}

/// `Generator<Y, R, N>`'s argument list read positionally; null when it has
/// no yield argument at all (`Iterable` written bare).
fn iterationCtxOf(args: []const TypeId) ?IterationCtx {
    if (args.len == 0) return null;
    return .{
        .yield = args[0],
        .ret = if (args.len >= 2) args[1] else types.no_type,
        .next = if (args.len >= 3) args[2] else types.no_type,
    };
}

/// The NEXT type of the `Generator<Y, R, N>` inferred for an unannotated
/// generator body: the CONTEXTUAL one when the contextual return type named a
/// generator that spells it, else `unknown`.
///
/// tsc's `getReturnTypeFromBody` builds the generator type from
/// `getIterationTypesOfGeneratorFunctionReturnType(contextualReturnType)`, so
/// `f1<0, 0, 1>(function* () { … })` infers `Generator<0, 0, 1>` — the `1` can
/// only come from the context, since nothing a body does pins down what a
/// caller hands to `.next()`. Hardcoding `unknown` made that argument diverge
/// and the call fail (`generatorYieldContextualType`).
pub fn inferredNextType(it: ?IterationCtx) TypeId {
    const n = (it orelse return types.unknown_type).next;
    return if (n == types.no_type) types.unknown_type else n;
}

/// Union of a tuple's element types (the element type used when a tuple
/// borrows `Array<T>` members).
///
/// A REST element stores its ARRAY type — `[string, ...number[]]` holds
/// `number[]` at index 1 — so its contribution to the union is that array's
/// ELEMENT. tsc keeps the element type in the tuple target's type arguments
/// and unions those, which is why `[string, ...number[]].slice(1)` is
/// `(string | number)[]` there and why `[string, ...any[]]` borrows
/// `Array<any>` (`string | any` collapses). Reading `.ty` straight gave
/// `(string | number[])[]`, and wrongly through every `Array<T>` member a
/// rest tuple borrows: `slice`, `map`, `concat`, `indexOf`, a spread of it
/// into an array literal. `tupleElemTypeAt` is the one place that rule lives.
pub fn tupleElementUnion(c: *Checker, t: TypeId) Error!TypeId {
    const s = &c.ts;
    const n = s.tupleLen(t);
    var parts: std.ArrayList(TypeId) = .empty;
    defer parts.deinit(c.scratch());
    for (0..n) |i| {
        const e = s.tupleElem(t, @intCast(i));
        try parts.append(c.scratch(), (try c.tupleElemTypeAt(t, @intCast(i))) orelse e.ty);
    }
    return s.makeUnion(c.scratch(), parts.items);
}

// =====================================================================
// the iteration protocol (`for..of`, spread, `for await`)
// =====================================================================

/// Element type of `for (x of expr)`, diagnosing TS2488 when `expr` is not
/// iterable. Arrays/tuples/strings resolve directly; everything else goes
/// through the `[Symbol.iterator]()` protocol (`iterationElementType`).
pub fn forOfElementType(c: *Checker, rt: TypeId, right_node: Node, is_await: bool) Error!TypeId {
    if (is_await) {
        if (try c.asyncIterationElementType(rt)) |e| return e;
        if (right_node != 0) {
            try c.diagFmt(2504, c.nodeSpan(right_node), "Type '{s}' must have a '[Symbol.asyncIterator]()' method that returns an async iterator.", .{try c.typeToString(rt)});
        }
        return types.any_type;
    }
    switch (try iterationOutcome(c, rt)) {
        .element => |e| return e,
        // tsc's `getIterationTypesOfMethod` splits the two failures: a type
        // with no `[Symbol.iterator]()` at all is TS2488, but one that HAS the
        // protocol and whose `next()` merely returns the wrong shape gets the
        // more specific `mustHaveAValueDiagnostic` — and then carries on with
        // `any` rather than bailing. `class MyStringIterator { next() { return
        // ""; } [Symbol.iterator]() { return this; } }` is exactly that
        // (`for-of15`).
        .next_result_lacks_value => {
            if (right_node != 0) {
                try c.diagFmt(2490, c.nodeSpan(right_node), "The type returned by the '{s}()' method of an iterator must have a 'value' property.", .{"next"});
            }
            return types.any_type;
        },
        .not_iterable => {},
    }
    if (right_node != 0) {
        try c.diagFmt(2488, c.nodeSpan(right_node), "Type '{s}' must have a '[Symbol.iterator]()' method that returns an iterator.", .{try c.typeToString(rt)});
    }
    return types.any_type;
}

/// `iterationElementType` under tsc's `mapType` semantics: a UNION
/// contributes the elements of the constituents that ARE iterable and
/// silently drops the ones that are not, instead of failing outright.
///
/// tsc's `getContextualTypeForElementExpression` ends in
/// `mapType(arrayContextualType, t => getIteratedTypeOrElementType(…))`, and
/// `mapType` collects the defined results. That is the CONTEXTUAL reading and
/// it is deliberately laxer than the `for..of` one: `for (x of xs)` demands
/// every constituent be iterable (TS2488), but an array literal under
/// `Iterable<T> | null | undefined` — the shape every optional
/// `iterable?: Iterable<T> | null` lib constructor parameter has — still
/// types its elements by `T`. Without it `new Set(["a", "b"])` in
/// `Set<"a" | "b">` position left its elements uncontextualized, they widened
/// to `string`, and `T` came out `string` (excalidraw's `bindingProperties`).
pub fn contextualIterationElementType(c: *Checker, rt: TypeId) Error!?TypeId {
    const r = try c.resolveStructural(rt);
    if (c.ts.kind(r) != .union_type) return iterationElementType(c, r);
    var parts: std.ArrayList(TypeId) = .empty;
    defer parts.deinit(c.scratch());
    for (try c.memberList(r)) |m| {
        if (try iterationElementType(c, m)) |e| try parts.append(c.scratch(), e);
    }
    if (parts.items.len == 0) return null;
    return try c.ts.makeUnion(c.scratch(), parts.items);
}

/// The type produced by iterating `rt` (the `x` in `for (x of rt)` and the
/// element of `[...rt]`), or null when `rt` is not iterable. Handles
/// arrays/tuples/strings directly, `Generator`/`Iterator`/`IterableIterator`
/// refs, and the general `[Symbol.iterator]() -> { next(): { value } }`
/// protocol (so `Map`/`Set` and user-defined iterables work).
pub fn iterationElementType(c: *Checker, rt: TypeId) Error!?TypeId {
    return switch (try iterationOutcome(c, rt)) {
        .element => |e| e,
        // A caller with no diagnostic site of its own (contextual typing, a
        // spread) keeps the pre-TS2490 answer: "not iterable". tsc would
        // substitute `any` after reporting, and reporting is what these
        // callers do not do — an under-report is the safe direction.
        else => null,
    };
}

/// Why `iterationElementType` could not produce an element, or the element.
/// Split out because tsc's two failures carry DIFFERENT diagnostics and only
/// `forOfElementType` has a node to hang them on.
pub const IterationOutcome = union(enum) {
    element: TypeId,
    /// No `[Symbol.iterator]()` protocol reached at all — tsc's TS2488.
    not_iterable,
    /// The protocol is present and `next()` is callable, but what it returns
    /// has no `value` property — tsc's TS2490.
    next_result_lacks_value,
};

fn iterationOutcome(c: *Checker, rt: TypeId) Error!IterationOutcome {
    const r = try c.resolveStructural(rt);
    switch (c.ts.kind(r)) {
        .array => return .{ .element = c.ts.arrayElem(r) },
        .tuple => return .{ .element = try c.numberIndexType(r) },
        .string, .string_literal => return .{ .element = types.string_type },
        .any, .err => return .{ .element = types.any_type },
        .union_type => {
            var parts: std.ArrayList(TypeId) = .empty;
            defer parts.deinit(c.scratch());
            for (try c.memberList(r)) |m| {
                switch (try iterationOutcome(c, m)) {
                    .element => |e| try parts.append(c.scratch(), e),
                    // One bad constituent decides the whole union, and its
                    // reason is the one worth reporting.
                    else => |why| return why,
                }
            }
            return .{ .element = try c.ts.makeUnion(c.scratch(), parts.items) };
        },
        // An INTERSECTION iterates through whichever constituents carry the
        // protocol, and the element is their intersection. tsc gets this for
        // free — `getPropertyOfType(X[] & Y[], Symbol.iterator)` is the
        // intersection of the two members, calling it yields
        // `ArrayIterator<X> & ArrayIterator<Y>`, and `next()`'s `value` comes
        // out `X & Y`. ztsc's `propOfType` finds no such member, so `X[] &
        // Y[]` reported a false TS2488 (`for-of58`). Constituents that are
        // NOT iterable are skipped rather than failing the whole type, which
        // matches the property lookup: `Foo[] & { tag: 1 }` still iterates.
        .intersection => {
            var parts: std.ArrayList(TypeId) = .empty;
            defer parts.deinit(c.scratch());
            var why: IterationOutcome = .not_iterable;
            for (try c.memberList(r)) |m| {
                switch (try iterationOutcome(c, m)) {
                    .element => |e| try parts.append(c.scratch(), e),
                    else => |w| why = w,
                }
            }
            if (parts.items.len == 0) return why;
            return .{ .element = try c.ts.makeIntersection(c.scratch(), parts.items) };
        },
        else => {},
    }
    // `[Symbol.iterator](): Iterator<E>` protocol.
    if (try c.propOfType(r, c.atom_sym_iterator)) |p| {
        // An OPTIONAL `[Symbol.iterator]?()` is not the protocol: tsc reads the
        // member's type with `| undefined` folded in, and a union with
        // `undefined` has no call signatures at all — so `{ [Symbol.iterator]?():
        // Iterator<string> }` is TS2488 (`for-of29`).
        if (p.optional()) return .not_iterable;
        // A member of type `any` satisfies the protocol outright, at either
        // hop: tsc's `getIterationTypesOfIterable` / `…OfMethod` answer
        // `anyIterationTypes` the moment the method (or its return) is `any`,
        // and never look for `next` (`for-of25`, `for-of27`).
        if (isAnyLike(c, try c.resolveStructural(p.ty))) return .{ .element = types.any_type };
        const ret = try zeroArgCallableReturn(c, p.ty);
        if (ret != 0) {
            if (isAnyLike(c, try c.resolveStructural(ret))) return .{ .element = types.any_type };
            // Lib iterables return `IterableIterator<E>`/`Iterator<E>`.
            const y2 = c.generatorYieldType(ret);
            if (y2 != 0) return .{ .element = y2 };
            // General protocol: the iterator's `next()` result `value`.
            switch (try iteratorNextOutcome(c, ret, false)) {
                .value => |v| return .{ .element = v },
                .no_value => return .next_result_lacks_value,
                .no_next => {},
            }
        }
    }
    return .not_iterable;
}

fn isAnyLike(c: *const Checker, t: TypeId) bool {
    return c.ts.kind(t) == .any or c.ts.kind(t) == .err;
}

/// The type produced by `for await (x of rt)`: the
/// `[Symbol.asyncIterator]()` protocol, falling back to the sync protocol
/// with `Awaited<…>` applied to the element (tsc allows `for await` over
/// a plain iterable). Null when `rt` is neither.
pub fn asyncIterationElementType(c: *Checker, rt: TypeId) Error!?TypeId {
    const r = try c.resolveStructural(rt);
    switch (c.ts.kind(r)) {
        .any, .err => return types.any_type,
        .union_type => {
            var parts: std.ArrayList(TypeId) = .empty;
            defer parts.deinit(c.scratch());
            for (try c.memberList(r)) |m| {
                const e = (try c.asyncIterationElementType(m)) orelse return null;
                try parts.append(c.scratch(), e);
            }
            return try c.ts.makeUnion(c.scratch(), parts.items);
        },
        else => {},
    }
    if (try c.propOfType(r, c.atom_sym_asyncIterator)) |p| {
        const ret = try zeroArgCallableReturn(c, p.ty);
        if (ret != 0) {
            const y = c.asyncGeneratorYieldType(ret);
            if (y != 0) return y;
            if (try c.iteratorNextValue(ret, true)) |v| return v;
        }
        return null;
    }
    if (try c.iterationElementType(rt)) |e| return try c.awaitedType(e);
    return null;
}

/// Return type of a callable prop (`.function` or the first `.overloads`
/// signature); 0 if `ty` is not callable.
pub fn callableReturn(c: *Checker, ty: TypeId) Error!TypeId {
    switch (c.ts.kind(ty)) {
        .function => return c.ts.fnReturn(ty),
        .overloads => {
            const sigs = try c.memberList(ty);
            return if (sigs.len > 0) c.ts.fnReturn(sigs[0]) else 0;
        },
        else => return 0,
    }
}

/// Return type of the signature the ITERATION PROTOCOL would actually reach:
/// the first one callable with NO arguments. 0 when `ty` is not callable, or
/// when every signature it has demands an argument.
///
/// The protocol invokes `[Symbol.iterator]()` / `[Symbol.asyncIterator]()`
/// with nothing, so a signature with a REQUIRED parameter is not the protocol
/// — tsc filters the call signatures by `getMinArgumentCount(sig) === 0`
/// (microsoft/TypeScript#57130) and reports TS2488 when none survive. An
/// optional or rest parameter still has a zero minimum and still qualifies
/// (`iteratorExtraParameters`, verified against the oracle both ways).
///
/// `next` deliberately does NOT go through this: the protocol DOES hand
/// `next` a value, so `next(v: T)` is a legal iterator — a `T` that
/// `undefined` cannot satisfy is tsc's separate TS2763, not a missing
/// protocol.
fn zeroArgCallableReturn(c: *Checker, ty: TypeId) Error!TypeId {
    switch (c.ts.kind(ty)) {
        .function => return if (minArgCount(c, ty) == 0) c.ts.fnReturn(ty) else 0,
        .overloads => {
            for (try c.memberList(ty)) |sig| {
                if (minArgCount(c, sig) == 0) return c.ts.fnReturn(sig);
            }
            return 0;
        },
        else => return 0,
    }
}

/// tsc's `getMinArgumentCount`: how many arguments a signature demands.
/// Optional and rest parameters demand none, and neither does anything after
/// the first of them.
fn minArgCount(c: *const Checker, sig: TypeId) u32 {
    const n = c.ts.fnParamCount(sig);
    var i: u32 = n;
    while (i > 0) : (i -= 1) {
        const p = c.ts.fnParam(sig, i - 1);
        if (!p.optional() and !p.rest()) return i;
    }
    return 0;
}

/// The `value` type of an iterator's `next()` result, i.e. the yield type
/// of an arbitrary (non-lib-named) iterator object. Null if `iter` has no
/// `next(): { value }` shape. With `is_async`, `next()`'s `Promise<…>`
/// return is unwrapped first (the `AsyncIterator` protocol).
pub fn iteratorNextValue(c: *Checker, iter: TypeId, is_async: bool) Error!?TypeId {
    return switch (try iteratorNextOutcome(c, iter, is_async)) {
        .value => |v| v,
        else => null,
    };
}

/// `iteratorNextValue` with tsc's two failures kept apart: `no_next` is "this
/// is not an iterator" (no `next` member, or one that is not callable), while
/// `no_value` is "it IS an iterator, but its result has no `value`" — the
/// distinction between TS2488 and TS2490 at the `for..of` site.
const NextOutcome = union(enum) { value: TypeId, no_next, no_value };

fn iteratorNextOutcome(c: *Checker, iter: TypeId, is_async: bool) Error!NextOutcome {
    const r = try c.resolveStructural(iter);
    const nextp = (try c.propOfType(r, c.atom_next)) orelse return .no_next;
    // `next: any` — or a `next()` that returns `any` — is tsc's
    // `anyIterationTypes` (`for-of26`, `for-of28`), not a missing protocol.
    if (isAnyLike(c, try c.resolveStructural(nextp.ty))) return .{ .value = types.any_type };
    var ret = try c.callableReturn(nextp.ty);
    if (ret == 0) return .no_next;
    if (is_async) ret = try c.awaitedType(ret);
    const rr = try c.resolveStructural(ret);
    if (isAnyLike(c, rr)) return .{ .value = types.any_type };
    if (c.ts.kind(rr) == .union_type) {
        // The lib's `next(): IteratorResult<T, TReturn>` is the union
        // `IteratorYieldResult<T> | IteratorReturnResult<TReturn>`,
        // discriminated on `done`: the iteration type is the `value` of
        // the constituents whose `done` is not literally `true`.
        var parts: std.ArrayList(TypeId) = .empty;
        defer parts.deinit(c.scratch());
        for (try c.memberList(rr)) |m| {
            const rm = try c.resolveStructural(m);
            if (try c.propOfType(rm, c.atom_done)) |dp| {
                if (c.ts.kind(try c.resolveStructural(dp.ty)) == .bool_true) continue;
            }
            const vp = (try c.propOfType(rm, c.atom_value)) orelse continue;
            try parts.append(c.scratch(), vp.ty);
        }
        if (parts.items.len == 0) return .no_value;
        return .{ .value = try c.ts.makeUnion(c.scratch(), parts.items) };
    }
    const valp = (try c.propOfType(rr, c.atom_value)) orelse return .no_value;
    return .{ .value = valp.ty };
}
