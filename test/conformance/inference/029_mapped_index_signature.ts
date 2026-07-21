// A homomorphic mapped type over an index-signatured source preserves that
// index signature — `Partial<Record<string, V>>` is `{ [k: string]: V |
// undefined }`, NOT `{}`. `keyof T` for an index-signatured source includes
// the primitive `string`/`number`, so the mapped value `T[K]` is remapped
// with K bound to that primitive and the signature survives.

// (1) Partial<Record<string, V>> keeps the string index signature.
type ChangedParams = Partial<Record<string, string | string[] | undefined>>;
function build(): ChangedParams {
  const params: ChangedParams = {};
  params['project_status'] = 'x';
  return params;
}
const p = build();
const a: string | string[] | undefined = p.project_status; // via index sig
const b = p['has_car'];

// (2) the `+?` modifier bakes `| undefined` into the index value type.
type PN = Partial<Record<string, number>>;
const pn: PN = {};
const pnv: number | undefined = pn.foo;

// (3) Readonly (no optional modifier) does NOT add undefined.
type RO = Readonly<Record<string, number>>;
const ro: RO = {};
const rov: number = ro.bar;

// (4) plain index-signature interface, not via Record.
interface IdxObj {
  [k: string]: number;
}
type PI = Partial<IdxObj>;
const pi: PI = {};
const piv: number | undefined = pi.anything;

// (5) number index signature is preserved and remapped with K = number.
type PNum = Readonly<Record<number, string>>;
const pnum: PNum = {};
const pnumv: string = pnum[3];

// (6) a custom homomorphic mapped type also preserves the index signature.
type MyPartial<T> = { [K in keyof T]?: T[K] };
type MP = MyPartial<Record<string, boolean>>;
const mp: MP = {};
const mpv: boolean | undefined = mp.flag;

// (7) NEGATIVE control: the optional modifier really did add `| undefined`,
// so assigning the index value to a non-optional target is an error (TS2322).
const bad: number = pn.missing;
