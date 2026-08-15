// A generic signature has to relate to ITSELF. Two rules make that work, and
// both are tsc's. Every line below is oracle-verified against tsgo 7.0.2.
//
//   * `instantiateSignatureInContextOf` infers the source's type parameters
//     from the target's PARAMETERS at priority 0 and from its RETURN at
//     `InferencePriority.ReturnType`, and a worse priority is DISCARDED, not
//     merged. Unioning the two positions' candidates bound the source's `V` to
//     `V_t | V_t & {…}` and the instantiation then had a wider parameter.
//   * a conditional's TRUE branch reads every reference to the check type
//     through a substitution type constrained by the extends type
//     (`getConditionalFlowTypeOfType`), so `V extends X ? V : …` offers
//     `V & X`, not a bare `V`.

// ------------------------------------------------------- self-assignability
declare function takeF(f: <V>(v: V) => V & {a: 1}): void;
declare function retF<V>(v: V): V extends {a: 1} ? V : V & {a: 1};
takeF(retF); // ok — the two `V`s are one after the instantiation

const asF: <V>(v: V) => V & {a: 1} = retF; // ok — same pair, assignment form

// The same through a type PREDICATE, whose asserted type is what gets related.
declare function takeP(p: <V>(v: V) => v is V & {$type: 'x'}): void;
declare function isP<V>(v: V): v is V extends {$type: 'x'} ? V : V & {$type: 'x'};
takeP(isP); // ok

// The target's parameter type arrives through an OUTER instantiation, which is
// atproto's `dangerousIsType(record, isRecord)` — 51 false positives on the
// parity-gated social-app before the two rules above.
type $Type<Id extends string, Hash extends string> = Hash extends 'main' ? Id : `${Id}#${Hash}`;
type $TypedObject<V, Id extends string, Hash extends string> = V extends {$type: $Type<Id, Hash>}
    ? V
    : V extends {$type?: string}
      ? V extends {$type?: infer T extends $Type<Id, Hash>}
        ? V & {$type: T}
        : never
      : V & {$type: $Type<Id, Hash>};
declare function dangerousIsType<R extends {$type?: string}>(
    record: unknown,
    identity: <V>(v: V) => v is V & {$type: NonNullable<R['$type']>},
): record is R;
interface Rec {
    $type: 'app.bsky.graph.starterpack';
    name: string;
}
declare function isRec<V>(v: V): v is $TypedObject<V, 'app.bsky.graph.starterpack', 'main'>;
declare const u: unknown;
const rec = dangerousIsType<Rec>(u, isRec); // ok

// ---------------------------------------------------------- the true branch
// Read one way each: the target's object half needs the substitution, its type
// parameter half needs the plain branch. Both readings, one conditional.
function subBoth<V>(x: V extends {a: 1} ? V : V & {a: 1}) {
    const y: V & {a: 1} = x; // ok
    const z: {a: 1} = x; // ok
    const w: V = x; // ok
}

// ------------------------------------------------------- negative controls
// The substitution is a property of the true BRANCH, not of the conditional:
// spelled as a plain union the same members do not relate.
function noSub<V>(x: V | (V & {a: 1})) {
    const y: V & {a: 1} = x; // TS2322
}

// A bare type parameter never acquires the extends type on its own.
function bare<V>(x: V) {
    const y: V & {a: 1} = x; // TS2322
}

// A true branch that does NOT mention the check type has nothing to substitute.
function noMention<V>(x: V extends {a: 1} ? {b: 2} : V & {a: 1}) {
    const y: {a: 1} & V = x; // TS2322
}

// The return-position inference still fires where the parameters bind nothing:
// dropping it outright (rather than out-prioritizing it) would break this.
declare function retOnly<T>(): T[];
declare function takeRet(f: () => string[]): void;
takeRet(retOnly); // ok
