//! The one NOMINAL rule inside the structural relation: tsc's
//! `private`/`protected` member screen in `propertiesRelatedTo`.
//!
//! Two classes that each declare `private a: string` are UNRELATED, however
//! identical their member types, because a `private` member is only ever the
//! one its own class declared — no value can satisfy two separate private
//! declarations of the same name. tsc spells the whole rule as a comparison of
//! the two property SYMBOLS' declarations, run before either member type is
//! related (`checker.ts`, `propertiesRelatedTo`):
//!
//!     if (sourceProp !== targetProp) {
//!         const sourcePropFlags = getDeclarationModifierFlagsFromSymbol(sourceProp);
//!         const targetPropFlags = getDeclarationModifierFlagsFromSymbol(targetProp);
//!         if (sourcePropFlags & ModifierFlags.Private || targetPropFlags & ModifierFlags.Private) {
//!             if (sourceProp.valueDeclaration !== targetProp.valueDeclaration) {
//!                 …Types_have_separate_declarations_of_a_private_property…
//!                 return Ternary.False;
//!             }
//!         } else if (targetPropFlags & ModifierFlags.Protected) {
//!             if (!isValidOverrideOf(sourceProp, targetProp)) {
//!                 …Property_0_is_protected_but_type_1_is_not_a_class_derived_from_2…
//!                 return Ternary.False;
//!             }
//!         } else if (sourcePropFlags & ModifierFlags.Protected) {
//!             …Property_0_is_protected_in_type_1_but_public_in_type_2…
//!             return Ternary.False;
//!         }
//!     }
//!
//! `isValidOverrideOf` is `hasBaseType(getDeclaringClass(sourceProp),
//! getDeclaringClass(targetProp))`: a `protected` target member accepts a
//! source member only from a class DERIVED from the one that declared it, which
//! is the same asymmetry the access-site rule has (TS2446 — one subclass cannot
//! read a sibling subclass's protected state).
//!
//! ztsc has no property symbols: a resolved `types.Prop` is a name, a type and
//! a flag word, and `prop_flag_non_public` is the only trace the declaration
//! leaves on it. The declaration side is therefore rediscovered the way
//! `accessibility.zig` rediscovers it at an access site — by walking the
//! receiver's declared heritage for the class whose member table declares the
//! name — and two properties are "the same symbol" exactly when that walk lands
//! on the same member symbol from both sides. That is the identity tsc's
//! `valueDeclaration` comparison observes: an INHERITED private member resolves
//! to the base's one symbol from the base and from every derived class, so
//! `class D extends A {}` still relates to `A`, while a re-declaration in `D`
//! is its own symbol and does not.
//!
//! NOT YET COVERED: ECMAScript `#private` NAMES. Oracled against tsgo 7.0.2 in
//! wave 22; every shape below is a diagnostic ztsc does not produce.
//!
//!     class A { #x = 1; a = 1 }
//!     class B { #x = 1; a = 1 }
//!     a = b;   // TS2322 + "Property '#x' in type 'B' refers to a different
//!              //           member that cannot be accessed from within type 'A'."
//!
//! The same for `#m(){}` and `get #g(){}`, in BOTH directions, and
//! order-independently. Everything adjacent already matches: `class D extends
//! C {}` still relates to `C` (one shared declaration), `{a:number}` vs a
//! class with `#x` is TS2741 both ways, and the soft-`private` sibling case is
//! the TS2322 above with tsc's OTHER message. `keyof A` should also be `"a"`
//! alone, where ztsc answers `"#x" | "a"`.
//!
//! What the relation needs, and why the name cannot supply it: ztsc keys a
//! `#x` member by the atom `#x`, which is the SAME atom a quoted `{"#x": 1}`
//! key produces — and that one IS a real key (`keyof {"#x": number}` is
//! `"#x"`). Testing the name therefore breaks quoted keys, and it is not
//! cheap either (see COST below). tsc has no such collision: a private
//! identifier's escaped name is mangled per class.
//!
//! So the missing half is agent A's, in the binder/`classes.zig`, and either
//! form works: `prop_flag_non_public` on the member (the three
//! `propertiesRelatedTo` gates and `keyof`'s own screen then admit it at no
//! cost, and `nonPublicPropMismatch` needs one arm returning tsc's
//! private-name message), or a per-class atom (`#x@A`), in which case the two
//! sides simply hold different names and this file needs an arm that reports
//! "different member" rather than letting the missing-property rule answer
//! TS2741.
//!
//! COST. Every caller screens on `prop_flag_non_public` first — already loaded
//! on the `Prop`/table slot the relation walk read to get the member's name —
//! so a program whose compared types have no non-public member anywhere pays
//! one predictable-false branch per property pair and nothing else. Only past
//! that bit does anything here run, and then it is the binder's member tables
//! and the already-memoized `declaredBaseRefs` heritage: no type is resolved
//! and no member type is instantiated.
//!
//! That bit is also why the private-name rule above waits for it rather than
//! reading names here: a name read is an interner lookup and
//! `Interner.lookup` takes the interner's shard mutex, so screening the
//! property walk on the NAME put a lock on the hot path — interleaved A/B on
//! drizzle, 4.28s -> 4.63s median (+7-8%) against a 2% bar.

const binder = @import("../frontend/binder.zig");
const intern = @import("../intern.zig");
const types = @import("../types.zig");

const Atom = intern.Atom;
const SymbolId = binder.SymbolId;
const TypeId = types.TypeId;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;

const accessibility = @import("accessibility.zig");
const Access = accessibility.Access;
const statics_zig = @import("statics.zig");

const classes = @import("classes.zig");
const max_heritage_nodes = classes.max_heritage_nodes;
const derivesFrom = classes.derivesFrom;

/// The screen for the one pair the property walk can never see: two distinct
/// REFERENCES whose member tables materialize to the very same type id.
///
/// ztsc hash-conses member tables, so `class A { private a: string }` and
/// `class B { private a: string }` are ONE object type — and the relation's
/// reference arm answers `rs == rt` as "related" without comparing a single
/// property. tsc has no such collapse (a class's instance type is a fresh
/// object per declaration), and the pair is precisely the one the nominal rule
/// is about: nothing structural distinguishes the two classes, only their
/// declarations do. So the shared table decides nothing here; the two
/// references' own declarations do.
///
/// Screened on the table's flag words first, so an identical-table pair with no
/// non-public member anywhere — the common case this shortcut exists for —
/// answers after one scan of already-resolved `Prop`s and no heritage walk at
/// all.
pub fn identicalTableRelated(c: *Checker, src: TypeId, dst: TypeId, table: TypeId) Error!bool {
    if (c.ts.kind(table) != .object) return true;
    const n = c.ts.objectPropCount(table);
    for (0..n) |i| {
        // One table, so its flags are BOTH sides' flags: a name non-public here
        // is non-public on the source and on the target.
        if (!c.ts.objectProp(table, @intCast(i)).nonPublic()) continue;
        const name = c.ts.objectProp(table, @intCast(i)).name;
        if (!try nonPublicPropRelated(c, src, dst, name, true, true)) return false;
    }
    return true;
}

/// Whether the property `name` — already known to carry
/// `prop_flag_non_public` on at least one of the two sides — may relate at all,
/// BEFORE its member types are compared. `false` is tsc's `Ternary.False`
/// straight out of `propertiesRelatedTo`.
///
/// `src` and `dst` are the two sides as the relation holds them: a `.ref`, or a
/// materialized object whose `origin` names one (`refFacetOf`). `*_non_public`
/// are the two `Prop` flag bits the caller already read.
///
/// A side that names no class at all — a type literal, a mapped type, an
/// anonymous object — yields no declaring symbol, and that is an ANSWER, not a
/// failure: its property is declared somewhere the other side's class is not, so
/// tsc's `valueDeclaration` comparison says "different" and a non-public
/// declaration on the OTHER side decides the pair. That is what makes
/// `{ a: string }` and a `class P { private a: string }` mutually unassignable in
/// both directions.
///
/// The one case that is neither is a side whose property CARRIES the non-public
/// flag and whose declaration this walk could not find — a member inherited
/// through a heritage clause that is not a plain reference (`class D extends
/// Mixin(Base)`), where the flag was folded into `D`'s own table without a
/// declaring symbol to attribute it to, or a static side two classes share
/// (`statics.staticOwner`). There the rule has no `valueDeclaration` to compare
/// and this answers `true`: an under-report, never a false positive.
pub fn nonPublicPropRelated(
    c: *Checker,
    src: TypeId,
    dst: TypeId,
    name: Atom,
    src_non_public: bool,
    dst_non_public: bool,
) Error!bool {
    return (try nonPublicPropMismatch(c, src, dst, name, src_non_public, dst_non_public)) == null;
}

/// WHICH of tsc's four terminal messages the pair earned, for the elaboration
/// re-walk (`elaborate.zig`) to render. `null` is "related".
///
/// The rule and its message are one decision in tsc — the `reportError` call
/// sits in the arm that returns `Ternary.False` — so they are one function here
/// too, and `nonPublicPropRelated` is this asked for its bit. Two copies of the
/// arm order would drift, and the drift would be a message that names a rule the
/// relation did not apply.
pub const Mismatch = union(enum) {
    /// `Types have separate declarations of a private property '{name}'.`
    separate_private,
    /// `Property '{name}' is private in type '{private_cls}' but not in type
    /// '{other}'.` — tsc names the PRIVATE side first whichever direction the
    /// assignment ran in. `private_statics` renders `typeof C` for a
    /// `private static`, which is how tsc's `typeToString(source)` prints the
    /// static side.
    private_one_side: struct { private_cls: SymbolId, private_statics: bool, other: TypeId },
    /// `Property '{name}' is protected but type '{src}' is not a class derived
    /// from '{tgt}'.`
    protected_not_derived: struct { src_cls: ?SymbolId, tgt_cls: SymbolId },
    /// `Property '{name}' is protected in type '{src}' but public in type
    /// '{tgt}'.` — the whole SOURCE and TARGET types, not the declaring classes,
    /// each in its DISPLAY form (`displayType`).
    protected_vs_public: struct { src: TypeId, tgt: TypeId },
};

/// The type as tsc PRINTS it in the messages above. A class's static side is a
/// plain object here and `typeof C` in tsc, so the reverse index that named its
/// class (`declaringMember`) names it for the message too; everything else is
/// already the type tsc holds.
fn displayType(c: *Checker, ty: TypeId) Error!TypeId {
    if (c.ts.kind(ty) == .class_value) return ty;
    const cls = statics_zig.staticOwner(c, ty) orelse return ty;
    return c.ts.makeClassValue(cls);
}

fn nonPublicPropMismatch(
    c: *Checker,
    src: TypeId,
    dst: TypeId,
    name: Atom,
    src_non_public: bool,
    dst_non_public: bool,
) Error!?Mismatch {
    const s = try declaringMember(c, src, name);
    const t = try declaringMember(c, dst, name);
    // tsc's `sourceProp !== targetProp` guard: one symbol reached from both
    // sides is one declaration, so an inherited non-public member relates and
    // `class D extends P {}` is still a `P`.
    if (s != null and t != null and s.?.msym == t.?.msym) return null;
    var s_access: Access = .public;
    if (s) |x| {
        s_access = accessibility.accessOfMember(c, x.msym, false);
    } else if (src_non_public or !try declaresOwnMember(c, src, name)) return null;
    var t_access: Access = .public;
    if (t) |x| {
        t_access = accessibility.accessOfMember(c, x.msym, false);
    } else if (dst_non_public or !try declaresOwnMember(c, dst, name)) return null;
    if (s_access == .private and t_access == .private) return .separate_private;
    if (s_access == .private) return .{ .private_one_side = .{
        .private_cls = s.?.cls,
        .private_statics = s.?.statics,
        .other = try displayType(c, dst),
    } };
    if (t_access == .private) return .{ .private_one_side = .{
        .private_cls = t.?.cls,
        .private_statics = t.?.statics,
        .other = try displayType(c, src),
    } };
    // `isValidOverrideOf`: a `protected` target member accepts only a source
    // member declared by a class DERIVED from the declaring one. A source with
    // no declaring class at all supplies none.
    //
    // "class" is literal — tsc's `isPropertyInClassDerivedFrom` reads the
    // source property's `getDeclaringClass`, which is `undefined` unless some
    // declaration's parent `isClassLike`, and answers `false` for it:
    //
    // ```ts
    // function isPropertyInClassDerivedFrom(prop: Symbol, baseClass: Type | undefined) {
    //     return forEachProperty(prop, sp => {
    //         const sourceClass = getDeclaringClass(sp);
    //         return sourceClass ? hasBaseType(sourceClass, baseClass) : false;
    //     });
    // }
    // ```
    //
    // So an INTERFACE that redeclares a base class's `protected` member as
    // public does not override it, however faithfully the interface extends
    // that class — `interface I extends Foo { x: string }` over
    // `class Foo { protected x: string }` is TS2430
    // (`interfaceExtendingClassWithProtecteds`,
    // `interfaceExtendingClassWithProtecteds2`). `declaringMember` walks
    // interfaces as well as classes because the property LOOKUP does, so the
    // class-ness of what it landed on is asked here.
    if (t_access == .protected) {
        if (s) |sc| {
            if (c.symFlags(sc.cls).class and try derivesFrom(c, sc.cls, t.?.cls)) return null;
        }
        return .{ .protected_not_derived = .{
            .src_cls = if (s) |sc| sc.cls else null,
            .tgt_cls = t.?.cls,
        } };
    }
    if (s_access == .protected) return .{ .protected_vs_public = .{
        .src = try displayType(c, src),
        .tgt = try displayType(c, dst),
    } };
    return null;
}

/// The mismatch for the FIRST target property that has one — the elaboration
/// re-walk's entry point, mirroring the order `propertiesRelatedTo` visits
/// properties in. `table` is the target's resolved member table, whose flag
/// words screen the walk exactly as the relation's own loop does.
pub fn firstMismatch(c: *Checker, src: TypeId, dst: TypeId, table: TypeId) Error!?Named {
    if (c.ts.kind(table) != .object) return null;
    for (0..c.ts.objectPropCount(table)) |i| {
        const tp = c.ts.objectProp(table, @intCast(i));
        const sp = (try c.propOfTypeEx(src, tp.name, false)) orelse continue;
        if (!sp.nonPublic() and !tp.nonPublic()) continue;
        if (try nonPublicPropMismatch(c, src, dst, tp.name, sp.nonPublic(), tp.nonPublic())) |m| {
            return .{ .name = tp.name, .why = m };
        }
    }
    return null;
}

pub const Named = struct { name: Atom, why: Mismatch };

/// tsc's `getTargetSymbol(sourceProp) === getTargetSymbol(targetProp)` half of
/// `compareProperties`: for a NON-PUBLIC property the identity relation asks
/// only whether the two sides name the same declaration — two `private a`
/// declarations are never identical however identical their types, and one
/// `protected a` reached from two different classes is the same member.
///
/// The direction-free counterpart of `nonPublicPropRelated`, which is the
/// *assignability* rule and therefore asymmetric (`isValidOverrideOf` accepts a
/// DERIVED source). `checkInheritedPropertiesIdentical` needs the symmetric one:
/// its two operands are two of an interface's bases, neither the source.
///
/// A side whose declaration this walk cannot find concedes (`true`), the same
/// under-report `nonPublicPropRelated` makes for the same shapes — a member
/// folded in through a non-reference heritage clause, or a shared static side.
pub fn sameNonPublicDeclaration(c: *Checker, a: TypeId, b: TypeId, name: Atom) Error!bool {
    const sa = try declaringMember(c, a, name) orelse return true;
    const sb = try declaringMember(c, b, name) orelse return true;
    return sa.msym == sb.msym;
}

/// Does `ty` DECLARE a member named `name`, as opposed to ANSWERING that name
/// through an index signature, through an `any` base, or through the global
/// `Object` augment?
///
/// tsc's premise for the whole rule is that both sides have a property SYMBOL:
/// `propertiesRelatedTo` reaches the accessibility arm only once
/// `getPropertyOfType(source, name)` has handed it one, and a name satisfied by
/// an index info has none. ztsc's `relationSrcProp` synthesizes a `Prop` for all
/// three of those cases, so the side with no declaring class has to be
/// distinguished from the side with no declaration at all — and it is exactly
/// this distinction that keeps `interface State extends AnyAlias {}` assignable
/// to a nominal class with a `private` member (`assignability/075`,
/// `assignability/076`: tsc relates such an interface AS `any`, so its
/// properties are not declarations of anything).
fn declaresOwnMember(c: *Checker, ty: TypeId, name: Atom) Error!bool {
    const r = try c.resolveStructural(ty);
    switch (c.ts.kind(r)) {
        .object => {
            for (0..c.ts.objectPropCount(r)) |i| {
                if (c.ts.objectProp(r, @intCast(i)).name == name) return true;
            }
            return false;
        },
        .intersection => {
            for (try c.memberList(r)) |m| {
                if (try declaresOwnMember(c, m, name)) return true;
            }
            return false;
        },
        else => return false,
    }
}

/// The class (or interface) symbol whose own member table declares `name`, plus
/// that member's symbol — tsc's `getDeclaringClass(prop)` and the property
/// symbol itself, which it has for free from the member table the lookup came
/// out of.
///
/// Breadth-first over the DECLARED heritage rather than the class `extends`
/// chain alone, because an interface may extend a class and several bases at
/// once, and the property lookup that produced the `Prop` followed the same
/// graph.
const Declaring = struct {
    cls: SymbolId,
    msym: SymbolId,
    /// Was the member found on the class's STATIC side (`typeof C`) rather than
    /// its instance side? Only the rendering differs — tsc names the static side
    /// `typeof C` where the instance side is plain `C` — but the two sides are
    /// separate member tables, so a `private static x` and a `private x` of the
    /// same class are different declarations and never the same symbol.
    statics: bool,
};

/// The class whose OWN member table declares `name`, on whichever side of the
/// class `ty` is.
///
/// The instance side is a `.ref` (or an object tagged with one), which names its
/// symbol directly. The static side is a plain materialized object — `typeof C`
/// carries no reference — so it names its class through the reverse index
/// `classStaticType` fills in (`statics.staticOwner`); that index is the whole
/// reason a `private static` shadow is a TS2417 here and was silently accepted
/// before.
fn declaringMember(c: *Checker, ty: TypeId, name: Atom) Error!?Declaring {
    const k = c.ts.kind(ty);
    var statics = false;
    const root = blk: {
        if (c.refFacetOf(ty, k)) |ref| break :blk c.ts.refSymbol(ref);
        if (k == .class_value) {
            statics = true;
            break :blk c.ts.classSymbol(ty);
        }
        if (statics_zig.staticOwner(c, ty)) |cls| {
            statics = true;
            break :blk cls;
        }
        return null;
    };
    var queue: [max_heritage_nodes]SymbolId = undefined;
    var seen: [max_heritage_nodes]SymbolId = undefined;
    var qn: usize = 1;
    var head: usize = 0;
    var n: usize = 0;
    queue[0] = root;
    while (head < qn) {
        const sym = queue[head];
        head += 1;
        if (n == seen.len) return null;
        var dup = false;
        for (seen[0..n]) |s| if (s == sym) {
            dup = true;
        };
        if (dup) continue;
        seen[n] = sym;
        n += 1;
        const found = if (statics)
            accessibility.staticMember(c, sym, name)
        else
            accessibility.instanceMember(c, sym, name);
        if (found) |msym| return .{ .cls = sym, .msym = msym, .statics = statics };
        // Statics are not inherited through an interface, and an interface has
        // no static side at all, so the static search stays on the class chain
        // (`accessibility.declaringClass` bounds its own walk the same way).
        if (statics and !c.symFlags(sym).class) continue;
        for (try c.declaredBaseRefs(sym)) |b| {
            if (c.ts.kind(b) != .ref or qn == queue.len) continue;
            queue[qn] = c.ts.refSymbol(b);
            qn += 1;
        }
    }
    return null;
}
