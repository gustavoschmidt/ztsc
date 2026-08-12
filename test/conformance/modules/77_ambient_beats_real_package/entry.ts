/// <reference types="fakenode" />
/// <reference path="./node_modules/@types/zipper/node_modules/@types/fakenode/index.d.ts" />
// Two copies of the same `@types` package, and a real npm package whose name
// collides with an ambient module — outline's `Buffer` shape, shrunk.
//
// `@types/zipper` depends on `@types/fakenode` and gets its own NESTED copy of
// it (a different version), so BOTH copies are in the program and both declare
// `declare module "sockbuf"` with a `global { interface SockBuf … }` block. tsc
// merges the two interfaces into the one global `SockBuf`, and — because
// `resolveExternalModuleName` looks an exactly-named ambient module up in the
// globals BEFORE consulting the resolved file — binds every `import { SockBuf }
// from "sockbuf"` to that ambient module, even though plain node resolution
// finds the real `node_modules/sockbuf` package (a browser polyfill exporting an
// unrelated `class SockBuf`). One type, everywhere.
//
// Every line below is silent when that holds and diagnosed otherwise, so the
// snapshot is the assertion. The `bad` line is the deliberate anchor: it prints
// the type ztsc actually settled on.
import { addBuffer, roundTrip } from "zipper";
import { SockBuf as Imported } from "sockbuf";

declare const g: SockBuf;

// The merged global interface has BOTH copies' members.
export const top: string = g.fromTop;
export const nested: number = g.fromNested;

// `@types/zipper` imported "sockbuf" from inside node_modules, where the real
// polyfill package sits next to it; its parameter must still be this SockBuf.
addBuffer(g);
export const back: SockBuf = roundTrip(g);

// Same rule from a project file: the ambient module, not `node_modules/sockbuf`.
export const imported: SockBuf = g satisfies Imported;

export const bad: number = g; // TS2322 — prints the type SockBuf resolved to
