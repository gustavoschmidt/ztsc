// tsc's `getSpreadType` over a UNION source carries the members' INDEX
// SIGNATURES into the result. `tryMergeUnionOfObjectTypeAndEmptyObject` first
// strips the members that spread the empty object (`undefined`, `null`, `{}`),
// and when exactly one carrier is left it is spread through
// `getAnonymousPartialType` — which makes the properties optional but keeps
// `getIndexInfosOfType(type)` verbatim. With two carriers tsc distributes and
// each arm keeps its own index.
//
// Minimized from outline's `server/queues/tasks/JSONAPIImportTask.ts`:
// `const attrs = { ...json.attrs }` where `attrs?: JSONObject` collapsed to
// `{}`, so every later `attrs.href` / `attrs.id` was a bogus TS2339.

type JSONValue = string | number | boolean | null | undefined;
type JSONObject = { [x: string]: JSONValue };

// POSITIVE: the string index survives a `| undefined` union spread, so an
// arbitrary key both reads and writes through it.
declare const optIdx: JSONObject | undefined;
const a = { ...optIdx };
const av: JSONValue = a.href;
a.href = "x";
void av;

// POSITIVE: `| null` behaves the same.
declare const nullIdx: { [k: string]: string } | null;
const b = { ...nullIdx };
const bv: string = b.anyKey;
void bv;

// POSITIVE: a NUMBER index signature is carried too.
declare const numIdx: { [n: number]: string } | undefined;
const c = { ...numIdx };
const cv: string = c[3];
void cv;

// POSITIVE: index signature alongside named members — the named prop becomes
// optional (the `undefined` member supplies nothing), the index stays.
declare const mixed: { n: number; [k: string]: unknown } | undefined;
const d = { ...mixed };
const dv: unknown = d.whatever;
const dn: number | undefined = d.n;
void dv;
void dn;

// POSITIVE: two carriers that BOTH declare a string index — the key reads as
// the union of their value types.
declare const two: { [k: string]: string } | { [k: string]: number };
const e = { ...two };
const ev: string | number = e.k;
void ev;

// POSITIVE: an EMPTY object member is stripped exactly like `undefined`.
declare const withEmpty: { [k: string]: string } | {};
const f = { ...withEmpty };
const fv: string = f.k;
void fv;

// NEGATIVE CONTROL (MUST error): one carrier has no index signature, so the
// spread result does not gain one — that arm still rejects the unknown key.
declare const partial: { [k: string]: string } | { a: string };
const g = { ...partial };
const gv = g.missing;
void gv;

// NEGATIVE CONTROL (MUST error): a `| undefined` spread of a CLOSED shape does
// not manufacture an index signature.
declare const closed: { a?: string } | undefined;
const h = { ...closed };
const hv = h.missing;
void hv;

export { a, b, c, d, e, f, g, h };
