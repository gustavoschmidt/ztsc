// A context-sensitive function argument that an overload candidate hands NO
// contextual signature is not an inference source, and walking it poisons the
// candidates that follow. Its un-annotated parameters become implicit `any`,
// so the type it yields is tsc's `anyFunctionType` — which `inferFromTypes`
// refuses — and the walk memoizes every identifier read INSIDE the body under
// the body's own (no-context) key. The next candidate re-types the parameter
// correctly and then reads those `any`s straight back.
//
// tsc runs `chooseOverload`'s first inference pass with `SkipContextSensitive`
// for exactly this reason. kysely's `select` is the shape that exposed it: the
// ARRAY overload is declared first, walks `(eb) => eb.ref('x').as('foo')`
// against `readonly any[]` — no call signature — and the single-expression
// overload beside it then inferred its type parameter as `(eb: any) => any`.

interface Aliased<O, A extends string> {
  readonly expression: O;
  readonly alias: A;
}

interface Eb {
  ref<C extends string>(c: C): Aliased<number, C>;
}

type Factory = (eb: Eb) => Aliased<any, any>;
type Expr = 'a' | 'b' | Aliased<any, any> | Factory;
type Callback = (eb: Eb) => ReadonlyArray<Expr>;

type AliasOf<E> = E extends string ? E
  : E extends Aliased<any, infer A> ? A
  : E extends (eb: any) => Aliased<any, infer A> ? A
  : never;
type Selection<E> = { [K in E as AliasOf<E>]: number };
type CallbackSelection<CB> = CB extends (eb: any) => ReadonlyArray<infer SE> ? Selection<SE> : never;

// The kysely declaration order: array, callback, single expression.
interface QB<O> {
  select<E extends Expr>(es: ReadonlyArray<E>): QB<O & Selection<E>>;
  select<CB extends Callback>(cb: CB): QB<O & CallbackSelection<CB>>;
  select<E extends Expr>(e: E): QB<O & Selection<E>>;
  row(): O;
}

declare const qb: QB<{ id: string }>;

// (1) inline arrow returning ONE aliased expression — the third overload
const r1 = qb.select((eb) => eb.ref('foo')).row();
const c1: number = r1.foo;
const i1: string = r1.id;

// (2) inline arrow returning an ARRAY — the second overload
const r2 = qb.select((eb) => [eb.ref('bar')]).row();
const c2: number = r2.bar;

// (3) an ANNOTATED parameter was never affected, and must not become so
const r3 = qb.select((eb: Eb) => eb.ref('baz')).row();
const c3: number = r3.baz;

// (4) a plain string selection still resolves to the same overload
const r4 = qb.select('a').row();
const c4: number = r4.a;

// (5) the parameter really does get its contextual type, not `any`
const r5 = qb.select((eb) => {
  const bad: string = eb; // Eb is not a string
  return eb.ref('qux');
});

export { c1, i1, c2, c3, c4, r5 };
