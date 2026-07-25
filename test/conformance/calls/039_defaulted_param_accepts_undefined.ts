// A parameter with an initializer is optional at the call site and accepts
// `undefined` (passing `undefined` triggers the default). Inside the body it
// keeps the non-undefined defaulted type.
function f(data: unknown, color = 'grey'): string {
  return color.toUpperCase(); // body sees `string`, not `string | undefined`
}
declare const c: string | undefined;
f(0, c); // ok: string | undefined accepted (defaulted param is optional)
f(0, undefined); // ok
f(0); // ok: defaulted param may be omitted
f(0, 42); // TS2345: number not assignable to string | undefined
