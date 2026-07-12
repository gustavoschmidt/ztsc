function f(x: { a: number } | undefined): number {
  if (!x) { return 0; }
  return x.a;
}
