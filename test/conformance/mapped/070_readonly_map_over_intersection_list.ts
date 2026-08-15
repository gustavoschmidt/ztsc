// A homomorphic map over an INTERSECTION with a list constituent: the map's own
// `+readonly`/`-readonly` does NOT reach the list. tsc materializes an anonymous
// object whose member set is `keyof src` — computed on the constituent as
// WRITTEN — so `Ro<Tup & Brand>` keeps the mutable list's members and is still
// spendable as `Tup`, while `Mutable<readonly Tup & Brand>` keeps the readonly
// list's members and still is not. (excalidraw's `Readonly<GlobalPoint>`
// parameters: 5 false TS2345/TS2352 when the map made the tuple readonly.)
type Ro<T> = { readonly [P in keyof T]: T[P] };
type Mutable<T> = { -readonly [P in keyof T]: T[P] };

type LP = [number, number] & { _brand: "lp" };
declare const a: Ro<LP>;
declare function takeLP(p: LP): void;
takeLP(a);
declare function takeRoTup(p: readonly [number, number]): void;
takeRoTup(a);
const first: number = a[0];
const len: number = a.length;

type RX = readonly [number, number] & { _brand: "rx" };
declare const b: Mutable<RX>;
declare const c: RX;
declare function takeTup(p: [number, number]): void;
takeTup(b); // TS2345
takeTup(c); // TS2345

type AB = number[] & { _brand: "ab" };
declare const d: Ro<AB>;
declare function takeArr(p: number[]): void;
takeArr(d);
declare function takeRoArr(p: readonly number[]): void;
takeRoArr(d);

// The non-intersection spellings keep the map's modifier (tsc's
// `instantiateMappedTupleType` / `instantiateMappedArrayType`).
declare const e: Ro<[number, number]>;
takeTup(e); // TS4104
declare const f: Ro<number[]>;
takeArr(f); // TS4104
