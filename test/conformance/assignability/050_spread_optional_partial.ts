// tsc's `getSpreadType` optionality rule: when a property is present in both
// the accumulated left of an object literal (`{ id, active, ... }`) and a later
// spread whose property is OPTIONAL (e.g. a `Partial<T>` override object), the
// result keeps the LEFT's optionality and unions the value types. So the
// explicitly-written required props of `{ id, active, ...overrides }` stay
// required and the literal is assignable to the fully-required target. This is
// the test-factory pattern `make(o: Partial<T> = {}): T => ({ ...defaults, ...o })`.

interface Full {
  id: string;
  active: boolean;
  status: string;
  attempts: number;
  note?: string;
}

// POSITIVE: every required Full prop is written explicitly before the optional
// spread, so they stay required — assignable, no error.
function make(overrides: Partial<Full>): Full {
  return {
    id: "x",
    active: true,
    status: "VALID",
    attempts: 0,
    ...overrides,
  };
}

// POSITIVE: an optional spread prop with no explicit left prop stays optional,
// but the target also has it optional — fine.
function make2(overrides: Partial<Full>): Full {
  return {
    id: "y",
    active: false,
    status: "OK",
    attempts: 1,
    note: "n",
    ...overrides,
  };
}

// NEGATIVE: a required target prop (`status`) is NOT written explicitly and is
// only supplied by the optional spread, so it stays optional — not assignable.
// tsc: TS2322.
function bad(overrides: Partial<Full>): Full {
  return {
    id: "z",
    active: true,
    attempts: 0,
    ...overrides,
  };
}

// NEGATIVE: a required target prop supplied only by a REQUIRED spread prop of an
// incompatible type — a required spread prop wins entirely (not merged), so the
// type mismatch stands. tsc: TS2322.
declare const req: { status: number };
function bad2(): Full {
  return {
    id: "w",
    active: true,
    attempts: 0,
    ...req,
  };
}

export { make, make2, bad, bad2 };
