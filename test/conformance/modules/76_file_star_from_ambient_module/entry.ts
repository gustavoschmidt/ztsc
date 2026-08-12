// `export * from "<ambient module>"` written at the TOP LEVEL of a declaration
// FILE. All three ways of reading the starrer's export table must see the
// starred names: the esModuleInterop synthesized default (which IS the module
// namespace object), the namespace import, and a named import.
import "ambdecl"; // brings the `declare module "ambmod"` block into the program

import def from "starpkg2";
import * as ns from "starpkg2";
import { starFn, StarCls, shadowed } from "starpkg2";
import type { StarIface } from "starpkg2";
import * as chained from "starpkg3";
import { relayFn, relayOwnFn } from "./relay";
import type { RelayIface } from "./relay";

// 1. synthesized default = the namespace object, star members included.
const s1: string = def.starFn(1);
const n1: number = new def.StarCls().m();
const b1: boolean = def.ownFn();

// 2. namespace import.
const s2: string = ns.starFn(1);
const n2: number = new ns.StarCls().m();

// 3. named import (value and type).
const s3: string = starFn(1);
const n3: number = new StarCls().m();
const iface: StarIface = { a: 1 };
const iface2: ns.StarIface = { a: 2 };

// 4. a star of a starrer settles too.
const s4: string = chained.starFn(1);
const b4: boolean = chained.ownFn();

// 5. the starrer's OWN declaration outranks the starred one.
const s5: string = shadowed();
const s6: string = ns.shadowed();

// 6. a named re-export of a star-contributed name carries its real type.
const s7: string = relayFn(1);
const b7: boolean = relayOwnFn();
const iface3: RelayIface = { a: 3 };

// Negative controls — the real starred declarations are in force, not `any`.
const bad1: number = def.starFn(1);
const bad2: string = ns.starFn(1).length;
const bad3: string = new StarCls().m();
const bad4: number = chained.starFn(1);
const bad5: number = shadowed();
const bad6: number = relayFn(1);
def.starFn("no");

export { s1, n1, b1, s2, n2, s3, n3, iface, iface2, s4, b4, s5, s6, s7, b7, iface3 };
export { bad1, bad2, bad3, bad4, bad5, bad6 };
