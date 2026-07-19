// Decidability rule: Awaited over a concrete-shaped object whose free type
// params live only in property values resolves (an object is never nullish
// and, lacking a `then` member, never thenable) — Promise.resolve of such a
// value is Promise<{ data: P }>, relating cleanly for every substitution.
function wrap<P>(x: P) {
  const p = Promise.resolve({ data: x });
  const q: Promise<{ data: P }> = p;
  return q;
}
async function use() {
  const r = await wrap(42 as const);
  const n: 42 = r.data;
}
