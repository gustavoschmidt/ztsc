// Reverse-mapped inference preserves the argument's modifiers, minus the ones
// the mapping itself ADDS (tsc's `resolveReverseMappedTypeMembers`):
//   `Readonly<P>` adds `readonly`  -> inferred P keeps `?`, drops `readonly`
//   `Partial<P>`  adds `?`         -> inferred P keeps `readonly`, drops `?`
//   `{ [K in keyof S]: S[K] }`     -> inferred S keeps both
// This is the React `memo(Component, propsAreEqual)` shape: the comparator
// parameter is `Readonly<P>`, so inferring `P` from it used to produce an
// all-REQUIRED props object and every use of the memoized component reported
// TS2739/TS2741 for props that are in fact optional.
type Props = { a?: string; readonly b: number };

interface FC<P> {
  (props: P): string | null;
}
declare function memo<P extends object>(
  Component: FC<P>,
  propsAreEqual?: (prev: Readonly<P>, next: Readonly<P>) => boolean,
): FC<P>;

const Base = (props: Props): string | null => null;
const areEqual = (p: Props, n: Props) => p.a === n.a;
const M = memo(Base, areEqual);
// `a` stayed optional, so this is a complete props object.
const okMemo: string | null = M({ b: 1 });
// Read the inferred `P` back out: `a` is still optional, `b` still required.
declare function propsOf<Q>(f: FC<Q>): Q;
const p = propsOf(M);
const okP: { a?: string; b: number } = p;
const badP: { a: string; b: number } = p;

// `Partial<P>` masks optionality off: the inferred `P` is all-required.
declare function fromPartial<Q>(q: Partial<Q>): Q;
const req = fromPartial({ a: "x" as string | undefined, b: 2 });
const okReq: { a: string | undefined; b: number } = req;

// A plain identity map keeps the argument's own modifiers.
type Ident<S> = { [K in keyof S]: S[K] };
declare function fromIdent<S>(s: Ident<S>): S;
const kept = fromIdent({ a: "x" } as { a?: string; c: number });
const okKept: { a?: string; c: number } = kept;
const badKept: { a: string; c: number } = kept;

export {};
