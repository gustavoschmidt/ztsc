// Loads the declaration file; every specifier below is an ambient module it
// declares, exactly as `@types/node` declares `"events"` and `"node:events"`.
import "evtspkg";

import { EE, Options } from "evts";
import { EE as EEViaAlias } from "evts-alias";
import EEDefault from "evts";
import { Renamed } from "evts2";

declare const a: EE;
declare const b: EEViaAlias;
declare const c: EEDefault;
declare const d: Renamed;
declare const o: Options;

// The class the alias names, reached three ways.
const n1: number = a.count;
const n2: number = b.count;
const n3: number = c.count;
const n4: number = d.m();
const b1: boolean = o.capture;

// Negative controls: the real declarations are in force, so the wrong type is
// still an error (an `any` from a dropped alias would have swallowed these).
const bad1: string = a.count;
const bad2: string = b.count;
const bad3: string = d.m();

export { n1, n2, n3, n4, b1, bad1, bad2, bad3 };
