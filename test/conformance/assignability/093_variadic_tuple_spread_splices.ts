// tsc's `createNormalizedTupleType`: a REST element whose type is itself a
// TUPLE contributes that tuple's elements positionally. `makeTuple` only
// normalized `[...X[]]` to `X[]`, so an INSTANTIATED variadic tuple kept the
// spread as a live element — and when the substituted tuple was EMPTY, the
// position it should have vanished from swallowed the elements after it.
//
// bluesky's storage API is the shape that found it: `Storage<[], Device>`
// substitutes `Scopes := []` into `[...Scopes, Key]`, which read as a
// two-element tuple whose first element is an empty tuple. Position 0 has no
// element type, so every `device.get(['fontScale'])` was
// "Type '"fontScale"' is not assignable to type 'never'".

declare class VtsStorage<Scopes extends unknown[], Schema> {
  get<Key extends keyof Schema>(scopes: [...Scopes, Key]): Schema[Key];
  set<Key extends keyof Schema>(scopes: [...Scopes, Key], data: Schema[Key]): void;
}

interface VtsDevice {
  fontScale: '0' | '1';
  fontFamily: 'system' | 'theme';
}

// The empty-tuple substitution: `[...[], Key]` IS `[Key]`.
declare const vtsDevice: VtsStorage<[], VtsDevice>;
const vtsA: '0' | '1' = vtsDevice.get(['fontScale']);
vtsDevice.set(['fontScale'], '0');

// A non-empty scope tuple splices positionally: `[...[string], Key]` is
// `[string, Key]`.
declare const vtsAccount: VtsStorage<[string], VtsDevice>;
const vtsB: 'system' | 'theme' = vtsAccount.get(['did:plc:x', 'fontFamily']);
vtsAccount.set(['did:plc:x', 'fontFamily'], 'theme');

// The splice is not about inference — explicit type arguments take the same
// route, and this was the form that proved the bug is in substitution.
declare function vtsExplicit<S extends unknown[], K>(a: [...S, K]): K;
const vtsC: string = vtsExplicit<[], string>(['x']);
const vtsD: string = vtsExplicit<[number], string>([1, 'x']);

// A spread in the MIDDLE, and a spread of a multi-element tuple.
declare function vtsMid<S extends unknown[]>(a: [boolean, ...S, string]): S;
const vtsE: [number, number] = vtsMid<[number, number]>([true, 1, 2, 'x']);

// A spread whose substitution is an ARRAY stays a rest element, so the tail
// is unbounded rather than positional.
declare function vtsArr<S extends unknown[]>(a: [boolean, ...S]): S;
const vtsF: number[] = vtsArr<number[]>([true, 1, 2, 3]);

// Nested: the inner tuple was itself normalized, so one splice suffices.
type VtsPair = [number, string];
declare function vtsNest<S extends unknown[]>(a: [...S, boolean]): S;
const vtsG: VtsPair = vtsNest<VtsPair>([1, 'a', true]);
