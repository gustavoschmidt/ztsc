// `export default <identifier>` is an ALIAS to the local entity and carries
// every meaning it has. Binding only the VALUE meaning made
// `import type A from "./cls"` resolve to `any`, so every annotation written
// against it silently checked nothing. (`export default class B {}` already
// worked — the declaration form binds a symbol.)
import type A from './cls';
import ACls from './cls';
import type Shape from './iface';
import ShapeVal from './iface';
import type Chained from './chain';

declare const a: A;
const a1: number = a.scene;
const a2: string = a.m();
const a3: string = a.scene; // TS2322

// The value meaning is still the class constructor.
const a4: A = new ACls();
const a5: string = new ACls(); // TS2322

// An interface + a same-named value: BOTH meanings come through.
declare const s: Shape;
const s1: number = s.n;
const s2: string = s.n; // TS2322
const s3: Shape = ShapeVal.make();

// `import X from "m"; export default X;` chains to the original entity.
declare const ch: Chained;
const c1: number = ch.scene;
const c2: string = ch.scene; // TS2322
