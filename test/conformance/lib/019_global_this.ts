// `globalThis` is always in scope (the global-scope object). ztsc resolves
// it to `any` rather than reporting TS2304, matching tsc's in-scope
// behavior. The common idiom is `(globalThis as any).x`.
const a = (globalThis as any)?.crypto;
const b: typeof globalThis = globalThis;

// A genuinely-unknown name still reports TS2304.
const d = totallyUndefinedName;
