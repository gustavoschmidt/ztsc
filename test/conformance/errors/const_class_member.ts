// `const` in a class-member modifier list is TS1248, reported on the member
// NAME. tsc accepts the keyword so the member behind it still parses —
// `static const H = 1` declares `H`, which is why the read below type-checks
// and the file has no other diagnostic.
class AtomicNumbers {
  static const H = 1;
}

const C = class {
  const a = 4;
};

const n: number = AtomicNumbers.H;
const bad: string = AtomicNumbers.H;
