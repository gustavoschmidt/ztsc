export interface Item {
  payload: {n: number}
}
export interface Bag {
  items: Item[]
}

// `V` is inferred from `main`'s ANNOTATED parameter; `after`'s parameter is
// un-annotated, which makes the whole object literal context sensitive.
export declare function run<V>(o: {
  main: (v: V) => void
  after: (v: V) => void
}): void
