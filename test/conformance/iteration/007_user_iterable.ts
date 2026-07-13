class Counter {
  [Symbol.iterator](): Iterator<number> {
    return null as any;
  }
}
for (const x of new Counter()) {
  const bad: string = x;
}
