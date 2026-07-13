function f(x: unknown) {
  if (typeof x === "symbol") {
    const s: symbol = x;
  }
}
