// A function-shaped type inherits the apparent members of the global
// `Function` interface (`bind`/`call`/`apply`/`name`/`length`/`toString`),
// exactly like tsc. This holds for bare function types, overload sets, and
// callable interfaces (one carrying a call signature). Plain, non-callable
// object types do NOT get these members.

// Bare arrow / function types.
declare const fn: (x: number) => string;
const b1 = fn.bind(null);
const c1 = fn.call(null, 1);
const a1 = fn.apply(null, [1]);
const n1: string = fn.name;
const l1: number = fn.length;
const s1: string = fn.toString();

// Arrow-typed const.
const arrow = (e: string): void => {};
const b2 = arrow.bind(null);

// Callable interface (a call signature plus a declared member).
interface Callable {
  (key: string): string;
  brand: string;
}
declare const t: Callable;
const b3 = t.bind(null);
const n3: string = t.name;
const br: string = t.brand; // declared member still resolves

// Overloaded function.
declare function ov(a: number): number;
declare function ov(a: string): string;
const b4 = ov.bind(null);

// Negative control: a made-up member on a callable still errors.
const bad1 = fn.nope; // TS2339
const bad2 = t.nope; // TS2339

// Negative control: a NON-callable object does NOT get Function members.
const plain = { geometry: "Polygon" as const };
const bad3 = plain.name; // TS2339
const bad4 = plain.bind; // TS2339
