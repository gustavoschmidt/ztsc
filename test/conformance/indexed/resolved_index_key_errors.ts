// tsc's `getPropertyTypeForIndexType` error tail, reached from a type NODE
// whose indexed access already RESOLVED — the half of indexed-access checking
// that TS2536 (a still-deferred `T[K]`) does not cover.
//
// Every position below is oracle-pinned against tsgo 7.0.2.

interface Foo { foo: string; common: number }
interface Bar { bar: string; common: number }

// The key must exist on the WHOLE union, not on some constituent: an access
// that distributes silently unions the miss away as `unknown`.
type U1 = (Foo | Bar)["foo"];   // TS2339 on the index
type U2 = (Foo | Bar)["common"];
type U3 = (Foo | Bar)["nope"];  // TS2339

// A single receiver, and an intersection, decide the same way.
type S1 = Foo["nope"];          // TS2339
type S2 = (Foo & { z: 1 })["nope"]; // TS2339
type S3 = { a: 1 }["a"];

// A key that is not string-, number- or symbol-like is TS2538 whatever the
// receiver is — the receiver is not consulted at all.
type K1 = Foo[boolean];         // TS2538
type K2 = Foo[void];            // TS2538
type K3 = Foo[null];            // TS2538
type K4 = Foo[any];             // TS2538
type K5 = Foo[never];
type K6 = Foo[symbol];          // TS2538 (no symbol index signature)

// `string` / `number` with no matching signature is TS2537.
type I1 = Foo[string];          // TS2537
type I2 = Foo[number];          // TS2537

// An index signature answers, and a NUMBER signature answers a numerically
// named string literal.
interface SI { [k: string]: number }
interface NI { [k: number]: number }
interface YI { [k: symbol]: number }
type A1 = SI["anything"];
type A2 = SI[string];
type A3 = NI["0"];
type A4 = NI[0];
type A5 = NI[string];           // TS2537
type A6 = SI[symbol];           // TS2538 — a string index does not serve a symbol key
type A7 = YI["x"];              // TS2339
type A8 = YI[symbol];

// A numeric literal past the end of a rest-free tuple names its arity; over a
// UNION of tuples it is a plain missing property, and a position present on
// ANY constituent still answers (the other contributes `undefined`).
type T1 = [string, number];
type T2 = [boolean] | [string, number];
type T3 = [string, ...number[]];
type R1 = T1[1];
type R2 = T1[2];                // TS2493
type R3 = T2[0];
type R4 = T2[1];
type R5 = T2[2];                // TS2339
type R6 = T3[9];

// A union index distributes and is judged key by key.
type D1 = Foo["foo" | "nope"];  // TS2339
