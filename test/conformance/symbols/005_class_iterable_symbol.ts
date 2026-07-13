class Seq {
  private items: number[] = [];
  [Symbol.iterator](): Iterator<number> {
    return this.items[Symbol.iterator]();
  }
}
for (const x of new Seq()) {
  const n: number = x;
  const bad: string = x;
}
