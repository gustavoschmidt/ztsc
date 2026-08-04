// An enum reference guarded by the RAW VALUE of one of its members, rather
// than by the member type. tsc's whole enum is the union of its member types,
// so `areTypesComparable(E.A, "a")` matches and both branches narrow.
enum E {
  A = "a",
  B = "b",
  C = "c",
}

declare const e: E;

function neq(): E.B | E.C {
  if (e !== "a") {
    return e;
  }
  throw new Error();
}

function eq(): E.A {
  if (e === "a") {
    return e;
  }
  throw new Error();
}

// Numeric enums behave the same way.
enum N {
  X = 1,
  Y = 2,
}
declare const n: N;
function num(): N.Y {
  if (n !== 1) {
    return n;
  }
  throw new Error();
}

// A discriminated union whose discriminant is an enum member, guarded both
// ways by the raw value.
type U = { k: E.A; a: number } | { k: E.B; b: string };
declare const u: U;
function discPos(): number {
  if (u.k === "a") {
    return u.a;
  }
  return 0;
}
function discNeg(): string {
  if (u.k !== "a") {
    return u.b;
  }
  return "";
}

// The whole point downstream: the TS 5.5 inferred type predicate needs the
// two branches to be disjoint, which the raw-value guard only makes them if
// the false branch subtracts the member.
declare const us: U[];
function found(): number {
  const hit = us.find((x) => x.k === "a");
  return hit ? hit.a : 0;
}
function kept(): string[] {
  return us.filter((x) => x.k !== "a").map((x) => x.b);
}

// A switch over the raw VALUES is deliberately NOT exhaustive in tsc (only a
// switch over the member types is), so this one still lacks an ending return.
function exhaustive(): string {
  switch (e) {
    case "a":
      return "A";
    case "b":
      return "B";
    case "c":
      return "C";
  }
}

export { neq, eq, num, discPos, discNeg, found, kept, exhaustive };
