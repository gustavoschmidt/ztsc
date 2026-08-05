// tsc's `getTupleTargetType`: "[...X[]] is equivalent to just X[]". A tuple
// whose only element is a rest element already spelled as an array carries no
// positional information the array form does not, so it IS the array.
//
// ztsc reified a parameter list as a tuple unconditionally, so
// `Parameters<(...args: any[]) => void>` came back `[...any[]]`. Nothing about
// that is visibly wrong until something infers THROUGH it:
// `ReadonlyArray<infer E>` matched the tuple and inferred `E = any[]` instead
// of `any`, which is how socket.io's `Last<Parameters<Map[K]>>` stopped being
// `any` and its whole `IsAny<…>` chain stopped reducing.

type Params<T extends (...args: any) => any> = T extends (...args: infer P) => any ? P : never;

type Last<V extends readonly unknown[]> = V extends readonly [infer E]
  ? E
  : V extends readonly [infer _, ...infer Tail]
    ? Last<Tail>
    : V extends ReadonlyArray<infer E>
      ? E
      : never;

// The reified list is the array, so it is not a 1-tuple…
type P1 = Params<(...args: any[]) => void>;
export const p1: P1 = [1, 2, 3];
type N1 = P1 extends readonly [infer _E] ? 'tuple' : 'array';
export const n1: N1 = 'array';

// …and inferring an element off it gives the element, not the list.
type E1 = P1 extends ReadonlyArray<infer E> ? E : never;
export const e1: E1 = 'anything';
type L1 = Last<Params<(...args: any[]) => void>>;
export const l1: L1 = 'anything';

// A concrete element type behaves the same way.
type P2 = Params<(...args: string[]) => void>;
export const p2: P2 = ['a'];
type L2 = Last<P2>;
export const l2: L2 = 'a';

// A leading fixed parameter still produces a real tuple.
type P3 = Params<(first: number, ...rest: string[]) => void>;
export const p3: P3 = [1, 'a', 'b'];
type L3 = Last<Params<(first: number, ...rest: string[]) => void>>;
export const l3: L3 = 'a';

// And a fully fixed list is a tuple, so `Last` takes the first branch.
type L4 = Last<Params<(a: number, b: string) => void>>;
export const l4: L4 = 'x';

export {};
