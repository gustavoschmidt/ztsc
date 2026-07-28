// Reading a variable can reach its declaration's flow node BEFORE the
// declaration statement is checked. The initializer is then checked from the
// flow query, and it must still be given the annotation as its contextual
// type — otherwise the arrow's parameters materialize as `any` and that answer
// is what the authoritative check reads back.
type CB = (props: { items: readonly string[]; count: number }) => void;
declare function take(cb: CB): number;

// checked first; inferring its return type demands `wrapper`, which reads
// `handle` before `handle`'s own declaration is checked
export const use = () => wrapper();

const handle: CB = ({ items, count }) => {
  const bad: number = items; // TS2322 — `items` is readonly string[], not any
  void bad;
  const bad2: string = count; // TS2322 — `count` is number, not any
  void bad2;
  const ok: readonly string[] = items;
  void ok;
  const ok2: number = count;
  void ok2;
};

function wrapper() {
  return take(handle);
}

// the same shape in ordinary order behaves identically
const handle2: CB = ({ items, count }) => {
  const bad3: number = items; // TS2322
  void bad3;
  void count;
};
export const use2 = () => take(handle2);

// an unannotated declaration is unaffected: no contextual type to supply
export const later = () => plain();
const cb = ({ x }: { x: string }) => {
  const bad4: number = x; // TS2322
  void bad4;
};
function plain() {
  return cb;
}
