// `any` is a narrowable subject: tsc's `narrowTypeByTypeof` opens with
// `isTypeAny(type)`, and `getNarrowedTypeWorker` returns the candidate outright
// for an `any`/`unknown` subject, so a type-predicate guard replaces it.
declare const d: any;
declare const u: unknown;

// typeof, both polarities
export const a = (x: any) => {
  if (typeof x !== "string") {
    return undefined;
  }
  return x;
};
export const a2 = (x: any) => {
  if (typeof x === "string") {
    return x;
  }
  return undefined;
};
export const a3: string | undefined = a(1);
export const a4: string | undefined = a2(1);

// typeof to each primitive
export const b = (x: any) => {
  if (typeof x === "number") {
    const n: number = x;
    return n;
  }
  if (typeof x === "boolean") {
    const t: boolean = x;
    return t;
  }
  if (typeof x === "bigint") {
    const g: bigint = x;
    return g;
  }
  if (typeof x === "symbol") {
    const s: symbol = x;
    return s;
  }
  if (typeof x === "undefined") {
    const v: undefined = x;
    return v;
  }
  return null;
};

// Array.isArray on `any` yields `any[]`, so the callback parameter is
// contextually typed (no implicit-any error) and `.length` resolves.
export const c1 = Array.isArray(d) ? d.map((x) => x) : null;
export const c2 = Array.isArray(u) ? u.map((x) => x) : null;
export const c3 = (x: any) => (Array.isArray(x) ? x.length : 0);

// a user-defined predicate replaces `any` too
type Box = { tag: "box"; n: number };
declare function isBox(v: unknown): v is Box;
export const e1 = (x: any) => {
  if (isBox(x)) {
    const n: number = x.n;
    return n;
  }
  return 0;
};

// instanceof on `any`
export const f1 = (x: any) => {
  if (x instanceof Error) {
    const m: string = x.message;
    return m;
  }
  return "";
};

// truthiness alone does not change `any`
export const g1 = (x: any) => {
  if (x) {
    const anything: number = x;
    return anything;
  }
  return 0;
};
