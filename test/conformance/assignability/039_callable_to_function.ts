// Any callable — arrow/normal functions, overload sets, classes used as
// values, callable object literals — is assignable to the global `Function`
// interface (tsc's apparent-type rule). Plain values are not.
const f1: Function = () => {};
function ov(a: number): number;
function ov(a: string): string;
function ov(a: any): any { return a; }
const f2: Function = ov;
class K { m(): void {} }
const f3: Function = K;
const lit: { (): void } = () => {};
const f4: Function = lit;
const bad: Function = 3;
declare function want(cb: string | Function): void;
want(() => {});
want(K);
const plain = { x: 1 };
want(plain);
