// Promise.all over an array literal picks the tuple overload:
// Promise<[A, B]>, element-precise (tsc/tsgo behavior), incl. .then and await.
declare const pa: Promise<{ data: number }>;
declare const pb: Promise<string>;
async function f() {
  const r = await Promise.all([pa, pb]);
  const a: number = r[0].data;
  const b: string = r[1];
  const bad: boolean = r[1]; // TS2322
}
Promise.all([pa, pb]).then((res) => {
  const x: { data: number } = res[0];
  const bad2: number = res[1]; // TS2322
});
// A plain (non-literal) array arg keeps the array shape and still resolves
// Awaited over the element.
declare const many: Promise<number>[];
async function g() {
  const rs = await Promise.all(many);
  const n: number = rs[0];
}
