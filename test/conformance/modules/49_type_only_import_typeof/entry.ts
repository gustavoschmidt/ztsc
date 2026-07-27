// A type-only import still denotes the imported entity in TYPE positions:
// `typeof X` is a type position, so it reaches the VALUE meaning. Only a
// *value* use is TS1361.
import type { App, V, E, NS } from "./lib";
import type D from "./lib";
import type * as All from "./lib";

declare const app: typeof App;
declare const inst: InstanceType<typeof App>;
declare const v: typeof V;
declare const d: typeof D;
declare const all: typeof All.App;
declare const ns: typeof NS.nv;
declare const e: typeof E;

// The queried types are the real ones, not `any`.
const a1: number[] = inst.m();
const a2: string = app.s;
const a3: number = v.a;
const a4: string = new d().d();
const a5: number[] = new all().m();
const a6: number = ns;
const a7: E = e.A;

// NEGATIVE: `any` would have swallowed every one of these.
const b1: string = inst.m();
const b2: number = app.s;
const b3: string = v.a;
const b4: number = new d().d();
const b5: string = new all().m();
const b6: string = ns;

// NEGATIVE: a type-only import in a VALUE position is still TS1361.
const c1 = App;
