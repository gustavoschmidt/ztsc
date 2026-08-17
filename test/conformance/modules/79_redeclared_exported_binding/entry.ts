// TS2323: a module's export list is a set of BINDINGS, so a name it exports
// twice is an error even where the declarations merge cleanly.

export var Foo = 2;
export var Foo = 42;

export var Three = 1;
export var Three = 2;
export var Three = 3;

// A function is one binding however many overload signatures it has; what
// collides is a second IMPLEMENTATION, and only the implementations are named.
export function overloaded(a: number): number;
export function overloaded(a: any): any {
    return a;
}
export function overloaded(a: any): any {
    return a;
}

// A clean overload set stays clean.
export function fine(a: number): number;
export function fine(a: string): string;
export function fine(a: any): any {
    return a;
}

// `export default function` publishes `default`; two of them collide the same
// way, and tsc names each function.
export default function dflt(a: number): number;
export default function dflt(a: string): string;
export default function dflt(a: any): any {
    return a;
}

// Not a redeclared binding:
//   * an `interface` merges into ONE exported binding;
//   * a `namespace` likewise;
//   * a name exported by a SPECIFIER is one binding however it was declared.
export interface Merged {
    a: number;
}
export interface Merged {
    b: number;
}

export namespace NS {
    export var inner = 1;
    export var inner = 2;
}

var local = 1;
var local = 2;
export { local };
