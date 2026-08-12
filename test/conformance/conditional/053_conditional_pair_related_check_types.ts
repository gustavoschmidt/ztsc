// Two deferred conditionals with IDENTICAL `extends` types relate BRANCH-WISE
// when their CHECK types are related in EITHER direction — tsc's
// `structuredTypeRelatedTo` conditional-against-conditional arm. ztsc used to
// require the two check types to be EQUAL.
//
// The consequence was not confined to a conditional written by hand: a
// DECLARATION-SITE VARIANCE MEASUREMENT substitutes a `sub`/`super` marker
// pair for the parameter it is measuring, which is exactly a pair of check
// types related in one direction only. A parameter used behind such a
// conditional therefore measured INVARIANT rather than covariant, and two
// instantiations of the generic then had to agree exactly. zod v4's
// `core.input<T>` / `core.output<T>` are that conditional, and
// `$ZodPipeDef<A, B>` puts them behind `transform`/`reverseTransform`.

type Z = { _zod: { input: any } };
type In<T> = T extends Z ? T["_zod"]["input"] : unknown;
type K<T> = T extends Z ? string : number;

// (1) the raw pair, both directions, over an unconstrained marker pair — the
// shape the variance measurement builds.
export function probe<Super, Sub extends Super>(a: In<Sub>, b: In<Super>, c: K<Sub>, d: K<Super>) {
  const p: In<Super> = a;
  const q: In<Sub> = b;
  const r: K<Super> = c;
  const s: K<Sub> = d;
  return [p, q, r, s];
}

interface Internals<O, I> {
  output: O;
  input: I;
}
interface Tr<O, I> {
  _zod: Internals<O, I>;
}
interface Box<T> {
  v: T;
}
interface Def<A, B> {
  out: B;
  reverseTransform?: (value: In<B>) => In<A>;
  // a UNION target for the conditional, which is the other place the
  // branch-wise rule has to fire (`util.MaybeAsync<core.input<B>>`).
  transform?: (value: In<A>) => In<B> | Box<In<B>>;
}
interface Pipe<A, B> {
  _zod: Internals<In<A>, In<B>>;
  _def: Def<A, B>;
}

type Rec = { [x: string]: unknown };
type Shape = { body: { id: string }; query: unknown };

// (2) the pair the measurement decides: `B` is used behind the conditional in
// BOTH a parameter and a return, so it measures covariant, not invariant.
declare const p1: Pipe<Tr<any, Rec>, Tr<any, Shape>>;
export const p2: Pipe<Tr<any, Rec>, Tr<any, Rec>> = p1;

// (3) NEGATIVE control: the rule relates the two conditionals, it does not
// relate the two type ARGUMENTS. `number` and `string` relate in neither
// direction, so this pair still fails.
declare const p3: Pipe<Tr<any, Rec>, Tr<any, number>>;
export const p4: Pipe<Tr<any, Rec>, Tr<any, string>> = p3;

// (4) NEGATIVE control: with no conditional in the way, a contravariant use
// of the parameter stays contravariant.
interface Plain<B> {
  rt?: (value: B) => void;
}
declare const p5: Plain<Shape>;
export const p6: Plain<Rec> = p5;

// (5) NEGATIVE control: same check type, unrelated branches.
type Br<T> = T extends Z ? T["_zod"]["input"] : string;
declare const p7: Br<Tr<any, Rec>>;
export const p8: K<Tr<any, Rec>> = p7;

// (6) NEGATIVE control: related check types but DIFFERENT `extends` types —
// the two conditionals need not resolve the same way, so no branch-wise rule.
type Y = { _zod: { output: any } };
type Out<T> = T extends Y ? string : number;
export function probe2<Super, Sub extends Super>(a: K<Sub>, b: Out<Super>) {
  const p: Out<Super> = a;
  const q: K<Sub> = b;
  return [p, q];
}
