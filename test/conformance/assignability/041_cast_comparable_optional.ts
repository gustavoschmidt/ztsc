// The as-cast overlap test uses the comparable relation: an optional source
// property may satisfy a required target property; truly disjoint shapes
// still TS2352.
interface Legend { color?: string; label: string }
interface A { key: string; legends: Legend[] }
interface B { key: string; kind: 'b'; legends?: Array<{ color: string; label: string }> }
declare const xs: A[];
const cast = xs as B[];       // ok: B -> A comparable with optional->required
declare const s: string;
const n = s as number;        // TS2352
declare const o: { a: string };
const bad = o as { b: number }; // TS2352
