// WHERE a failing object-literal argument is reported.
//
// tsc elaborates the literal per property (`elaborateObjectLiteral`) and the
// elaboration REPLACES the top-level TS2345, so a property that is PRESENT but
// mismatched is reported as its own TS2322 at the innermost failing property
// assignment — and nothing is reported at the argument's `{`. That holds for an
// INTERSECTION parameter exactly as for a lone object: `elaborateObjectLiteralError`
// bails only on a PRIMITIVE or `never` target, and
// `getIndexedAccessTypeOrUndefined` names a property of an intersection through
// `getPropertyOfUnionOrIntersectionType`.
//
// A literal that is only MISSING properties has nothing to elaborate and keeps
// the single report at the argument.
export {};

interface Big {
  a: string;
  b: string;
  c: string;
  req: { get(k: string): string };
}
declare function take(x: Big & { extra?: 1 }): void;
declare function takePlain(x: Big): void;

// A bad property AND missing ones: only the property is reported (line 27).
take({
  req: { get: 1 as unknown as number },
});

// Nothing bad, only missing: one report at the argument (line 31).
take({
  req: { get: (_k: string) => "" },
});

// A bad property, nothing missing (line 40).
take({
  a: "",
  b: "",
  c: "",
  req: { get: 1 as unknown as number },
});

// The lone-object target has always behaved this way — the control (line 45).
takePlain({
  req: { get: 1 as unknown as number },
});

// A DEEPER intersection, and the mismatch one level further in (line 51).
declare function deep(x: { p: { q: { r: string } } } & { extra?: 1 }): void;
deep({
  p: { q: { r: 1 as unknown as number } },
});

// An optional target property still accepts `undefined` — no report here.
declare function opt(x: { a: string } & { b?: number }): void;
declare const maybe: number | undefined;
opt({ a: "", b: maybe });

// A property the intersection declares nowhere is excess, not a mismatch, and
// the excess-property check (not the elaboration) owns it (line 61).
opt({ a: "", zzz: 1 });
