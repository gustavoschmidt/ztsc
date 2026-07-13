interface Bag { [Symbol.iterator](): IterableIterator<boolean>; }
declare const bag: Bag;
for (const x of bag) {
  const b: boolean = x;
  const bad: string = x;
}
