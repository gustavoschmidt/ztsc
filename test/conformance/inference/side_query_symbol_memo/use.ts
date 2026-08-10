import {type Bag, run} from './lib'

export const started = run({
  main: ({bag}: {bag: Bag}) => {
    void bag
  },
  after: ({bag}) => {
    for (const item of bag.items) {
      // `item` is `Item`, so this is a TS2322. Under the leak `item` came out
      // of the memo as `any` and nothing here was checked.
      const wrong: string = item.payload.n
      void wrong
    }
  },
})
