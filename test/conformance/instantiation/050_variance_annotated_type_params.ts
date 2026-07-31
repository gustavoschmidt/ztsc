// TS 4.7 VARIANCE ANNOTATIONS on type parameters (`in`, `out`, `in out`).
//
// `in` and `const` are reserved words, so the parser's modifier switch — which
// only runs for a token that is NOT identifier-like — saw them. `out` is a
// CONTEXTUAL keyword: it is identifier-like, never reached that switch, and was
// taken as the type parameter's NAME. The real name that followed it was then a
// syntax error, and the whole declaration was lost.
//
// That silently deleted every `<out T>` generic in a dependency. zod v4 declares
// `$ZodTypeInternals<out O = unknown, out I = unknown>`, so it came out with one
// parameter and no defaults; `$ZodType`'s `Internals extends $ZodTypeInternals<O,
// I> = $ZodTypeInternals<O, I>` default was then an arity error, `_zod` resolved
// to `unknown`, and `core.output<T> = T extends { _zod: { output: any } } ?
// T["_zod"]["output"] : unknown` took its false branch — collapsing every
// `z.infer<…>` in a zod-typed public API to `unknown`.
//
// `out` is the modifier exactly when a name can follow it (tsc's
// `parseAnyContextualModifier` -> `canFollowModifier`); otherwise it is an
// ordinary parameter name, which is legal and must keep working.

// `out` as a MODIFIER.
interface Internals<out O = unknown, out I = unknown> {
  output: O;
  input: I;
}
interface Boxed<
  O = unknown,
  I = unknown,
  Int extends Internals<O, I> = Internals<O, I>,
> {
  _z: Int;
}
type OutputOf<T> = T extends { _z: { output: any } } ? T["_z"]["output"] : unknown;

type Payload = { id: string };
declare const box: Boxed<Payload>;

const okOut: Payload = box._z.output;
const okProjected: Payload = null as unknown as OutputOf<typeof box>;

// The projection is a real type, not `unknown` — reading a property it does not
// have is still an error.
const badProjected: number = null as unknown as OutputOf<typeof box>; // TS2322

// `in`, and both together, in either order.
interface Sink<in A> {
  take(a: A): void;
}
interface Both<in out T> {
  v: T;
}
declare const sink: Sink<string>;
declare const both: Both<string>;
const badSink: number = sink; // TS2322
const badBoth: number = both.v; // TS2322

// `out` as a NAME — `<out>`, `<out, T>` and `<out = X>` all still declare a
// parameter called `out`, exactly as tsc parses them.
interface NamedOut<out> {
  a: out;
}
interface NamedOutThenParam<out, T> {
  a: out;
  b: T;
}
interface NamedOutDefaulted<out = string> {
  a: out;
}
declare const n1: NamedOut<string>;
declare const n2: NamedOutThenParam<string, number>;
declare const n3: NamedOutDefaulted;
const badN1: number = n1.a; // TS2322
const badN2: number = n2.a; // TS2322
const badN3: number = n3.a; // TS2322

// The modifier is not limited to interfaces (it is limited TO classes,
// interfaces and type aliases — a function type parameter cannot carry one).
type AliasOut<out T> = { v: T };
declare class ClassOut<out T> {
  v: T;
}
declare const a1: AliasOut<string>;
declare const c1: ClassOut<string>;
const badAlias: number = a1.v; // TS2322
const badClass: number = c1.v; // TS2322

export {
  okOut,
  okProjected,
  badProjected,
  badSink,
  badBoth,
  badN1,
  badN2,
  badN3,
  badAlias,
  badClass,
};
