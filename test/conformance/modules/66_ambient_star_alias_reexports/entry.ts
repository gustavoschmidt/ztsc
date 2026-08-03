import "starpkg";

import { CP, Options } from "node:cproc";
import { CP as CP2 } from "node:cproc2";

declare const p: CP;
declare const q: CP2;
declare const o: Options;

const n1: number = p.pid;
const n2: number = q.pid;
const b1: boolean = o.shell;

// The overload set survives the alias, so the callback written for the literal
// event overload is contextually typed (no implicit-`any` parameter).
p.on("exit", (code) => code + 1);

// Negative controls: the real declarations are in force.
const bad1: string = p.pid;
const bad2: string = q.pid;
const bad3: number = o.shell;

export { n1, n2, b1, bad1, bad2, bad3 };
