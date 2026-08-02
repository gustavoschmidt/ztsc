/// <reference path="./ambient.d.ts" />
declare const direct: typeof import("asserts").ok;
declare const aliased: typeof import("node:asserts").equal;
declare const opts: import("node:asserts").Options;

direct(1);
aliased(1, 2);
const s: boolean = opts.strict;
const bad: number = opts.strict;
direct();
export {};
