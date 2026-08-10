// The other half of 105: an optional chain narrows its receiver only INSIDE
// the chain. Afterwards the flow joins the short-circuit edge back in, so the
// receiver is nullish again — and on the `else` branch of a chain condition it
// was never tested at all.
interface Inner {
  at(n: number): string;
}
interface Outer {
  inner?: Inner;
  recId: number;
}
declare const o: Outer | undefined;

o?.inner?.at(o.recId);
// Past the end of the chain the receiver is nullish again.
const a: Inner | undefined = o.inner;

// The false outcome of a chain condition includes the short-circuit edge.
if (o?.inner) {
  const b: Inner = o.inner;
} else {
  const c: Inner | undefined = o.inner;
}

// A parenthesized chain that is not itself the receiver of the next link
// really does end: `(o?.inner)` is evaluated, then `.at` is read from it.
const d: string = (o?.inner).at(0);

// A `?.` guards only the links to its right.
declare const p: { q?: { r(): void } } | undefined;
p?.q?.r();
const e: { r(): void } | undefined = p.q;

export { a, d, e };
