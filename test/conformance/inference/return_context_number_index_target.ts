// tsc's `inferFromIndexTypes`, in the direction where the INFERENCE TARGET is
// an array type. `U[]` is a reference to `Array<U>`, whose apparent members
// include `[n: number]: U`, so a source object that declares a number index
// pairs with it and fixes `U` outright — even when the source is not iterable
// and shares no type reference with `Array`.
//
// The observable case is CONTEXTUAL-RETURN inference through `Array.concat`:
// `concat(...items: ConcatArray<T>[])` gives the argument the contextual type
// `ConcatArray<Slice>`, and `ConcatArray` has a number index but no
// `[Symbol.iterator]`. Without index pairing `U` in `map`'s `U[]` return stayed
// unbound, the arrow body got no contextual type, its object literal widened
// (`type: string` rather than `type: "popularFeed"`), and every `concat`
// overload rejected it — TS2769 on a call tsc accepts.

type Slice =
  | {type: 'header'; key: string}
  | {type: 'popularFeed'; key: string; feedUri: string};

declare const feeds: {uri: string}[];

let slices: Slice[] = [];
slices = slices.concat(
  feeds.map(feed => ({
    key: `popularFeed:${feed.uri}`,
    type: 'popularFeed',
    feedUri: feed.uri,
  })),
);

// The same pairing, spelled out: a bare interface with only a number index is
// enough to fix the element type of an array-returning generic call.
interface Indexed<T> {
  readonly [n: number]: T;
  readonly length: number;
}
declare function makeArray<U>(f: () => U): U[];
declare function takeIndexed(x: Indexed<{tag: 'a'; n: number}>): void;
takeIndexed(makeArray(() => ({tag: 'a', n: 1})));

// A rest parameter of the same shape resolves identically.
declare function takeRest(...items: ConcatArray<Slice>[]): void;
takeRest(feeds.map(feed => ({key: 'k', type: 'popularFeed', feedUri: feed.uri})));

// Negative: the source's number index still has to FIT. A `string` index type
// against a `number[]` target is a real error, not a silent inference.
declare function wantNumbers(): number[];
const bad: Indexed<string> = wantNumbers();

export {slices, bad};
