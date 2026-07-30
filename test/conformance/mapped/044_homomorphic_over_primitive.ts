// A homomorphic mapped type instantiated with a PRIMITIVE performs no mapping:
// the result is the primitive itself (tsc's `instantiateMappedType` — only
// `AnyOrUnknown | InstantiableNonPrimitive | Object | Intersection` is
// materialized, everything else is returned unchanged). It used to fall through
// to `{}` here, and an object where tsc has a primitive flips every
// `T[K] extends object` test one level up — react-hook-form's
// `DeepRequired<T>` / `FieldErrorsImpl<T>` / `Merge<A, B>` chain, whose form
// error values all read as `unknown` as a result.
interface NotAnObject {
  tag: "date";
}

type Hom<T> = { [K in keyof T]: T[K] };
type Req<T> = { [K in keyof T]-?: T[K] };

// The map is the primitive, so it is NOT an object.
type IsObj<T> = T extends object ? "OBJ" : "PRIM";
const p1: IsObj<Hom<string>> = "PRIM";
const p2: IsObj<Req<number>> = "PRIM";
const p3: IsObj<Hom<boolean>> = "PRIM";
const p4: IsObj<Hom<"lit">> = "PRIM";
const p5: IsObj<Hom<{ a: 1 }>> = "OBJ";

// …and it still relates as the primitive.
const s1: string = null! as Hom<string>;
const n1: number = null! as Req<number>;
const bad1: string = null! as Hom<number>; // TS2322

// `NonNullable<T>` is `T & {}`: the `{}` is a supertype of every non-nullish
// type, so an INSTANTIATED `X & {}` reduces to `X` — including through a lazy
// recursive-alias reference. A `{}` written next to a bare `string`/`number`/
// `bigint`/template-literal in SOURCE is the "any string, keep the literal
// completions" idiom and keeps its `{}` (tsc's `IntersectionFlags.
// NoSupertypeReduction`), so `string & {}` is still an object there.
const q1: IsObj<NonNullable<string>> = "PRIM";
const q2: IsObj<string & {}> = "OBJ";
const q3: NonNullable<{ a: 1 }> = { a: 1 };

// The whole chain: a recursive `DeepRequired` whose value re-enters itself
// through `NonNullable`, feeding a `FieldErrorsImpl`-shaped conditional whose
// object test decides between a `Merge`-style map and the leaf record. The
// INNER map's key set is `keyof T[K]` — the OUTER map's key parameter — so it
// must stay deferred until each key is bound, not materialize against an
// unresolved source.
type DeepRequired<T> = T extends NotAnObject
  ? T
  : { [K in keyof T]-?: NonNullable<DeepRequired<T[K]>> };

type Leaf = { message?: string; kind: "leaf" };

type Merge<A, B> = {
  [K in keyof A | keyof B]?: K extends keyof A & keyof B
    ? B[K]
    : K extends keyof A
      ? A[K]
      : K extends keyof B
        ? B[K]
        : never;
};

type ErrorsImpl<T> = {
  [K in keyof T]?: T[K] extends object ? Merge<Leaf, ErrorsImpl<T[K]>> : Leaf;
};

type Form = { email: string; count: number; nested: { flag: boolean } };

// A primitive field takes the LEAF arm: `message` is `string | undefined`.
declare const errs: ErrorsImpl<DeepRequired<Form>>;
const m1: string | undefined = errs.email?.message;
const m2: string | undefined = errs.count?.message;
const m3: number | undefined = errs.email?.message; // TS2322

// `DeepRequired` of a primitive field is that primitive, so the leaf arm is the
// one selected — reading it as an object is an error.
type EmailErr = ErrorsImpl<DeepRequired<Form>>["email"];
const m4: IsObj<DeepRequired<Form>["email"]> = "PRIM";
const m5: EmailErr = { kind: "leaf" };
const m6: EmailErr = { kind: "nope" }; // TS2322
