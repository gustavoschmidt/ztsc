function* g(): Generator<number> {
  yield 1;
}
for (const x of g()) {
  const bad: string = x;
}
