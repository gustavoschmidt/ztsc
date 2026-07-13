// The call's receiver must be assignable to the `this` parameter's type
// (TS2684). `good.stamp()` is fine (has `id`); `bad.stamp()` is not.
interface HasId {
  id: number;
}
function stamp(this: HasId): number {
  return this.id;
}
const good = { id: 1, stamp };
const a: number = good.stamp();
const bad = { stamp };
const b: number = bad.stamp();
