// A derived class's member table must never be MEMOIZED over a base whose
// materialization is a frame further down the same stack.
//
// `CollectionsStore extends Store<Collection>` and `Store`'s own members reach
// back to `CollectionsStore` through `RootStore`, so substituting `Collection`
// into `Store`'s generic table re-enters `CollectionsStore`. At that moment
// `Store`'s GENERIC table is complete — only the instantiation
// `Store<Collection>` is in flight — so the "is my base still materializing"
// guard was satisfied while `Store<Collection>` answered `err`, the base merge
// dropped every inherited member, and the 2-member remainder was published as
// `CollectionsStore`'s table for the rest of the run.
//
// Whichever demand order gets there first decided the answer, so the verdict
// moved with the file partition. Every inherited member below must resolve.

abstract class Model {
  id!: string;
}

abstract class Store<T extends Model> {
  data: Map<string, T> = new Map();
  isLoaded = false;
  rootStore!: RootStore;

  add(item: T): T {
    return item;
  }

  fetch(id: string): T | undefined {
    return this.data.get(id);
  }

  // Un-annotated, so checking it runs inside `Store`'s member window and
  // reaches the derived class through the root store.
  get first() {
    return this.rootStore.collections.orderedData[0];
  }
}

class Collection extends Model {
  name!: string;
}

class CollectionsStore extends Store<Collection> {
  get orderedData(): Collection[] {
    return [];
  }
  move(): void {}
}

class RootStore {
  collections = new CollectionsStore();
}

declare const s: CollectionsStore;

// Inherited from `Store<Collection>` — all of these were TS2339.
s.add(new Collection());
s.fetch("x");
s.isLoaded;
s.rootStore;
s.data;
s.first;

// The derived class's own members, which survived even when the fold cut.
s.orderedData;
s.move();

// Still not a member, either way.
s.nope;
