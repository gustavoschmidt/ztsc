// The splice must not become permissive: after `[...S, K]` is normalized the
// resulting positions are still checked, and the ARITY the splice computes is
// exactly as binding as a hand-written tuple's.

declare class VtsnStorage<Scopes extends unknown[], Schema> {
  get<Key extends keyof Schema>(scopes: [...Scopes, Key]): Schema[Key];
}

interface VtsnDevice {
  fontScale: '0' | '1';
}

declare const vtsnDevice: VtsnStorage<[], VtsnDevice>;

// Wrong key: `Key` is constrained to `keyof Schema`.
const vtsnA = vtsnDevice.get(['nope']);

// Too many elements once `[...[], Key]` has collapsed to `[Key]`.
const vtsnB = vtsnDevice.get(['fontScale', 'fontScale']);

// The spliced element type is still enforced.
declare function vtsnMid<S extends unknown[]>(a: [boolean, ...S, string]): S;
const vtsnC = vtsnMid<[number, number]>([true, 1, 'bad', 'x']);

// And so is the spliced arity.
const vtsnD = vtsnMid<[number, number]>([true, 1, 'x']);

// A spliced position keeps the element's own type: `[...[number], K]` is
// `[number, K]`, not `[any, K]`.
declare function vtsnExplicit<S extends unknown[], K>(a: [...S, K]): K;
const vtsnE = vtsnExplicit<[number], string>(['not a number', 'x']);
