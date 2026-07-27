/// <reference path="./globals.d.ts" />
import ns from "namedonly";
import dd from "hasdefault";

// `ns` is the synthesized default: the module's namespace object.
export const a: number = ns.value;
export const b: string = ns.helper();
export const c: number = dd;

// ...and it keeps its members' real types, so this still reports.
export const wrong: string = ns.value;
