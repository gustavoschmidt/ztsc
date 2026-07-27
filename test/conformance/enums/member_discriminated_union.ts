export {};
// A union discriminated by ENUM MEMBERS narrows like one discriminated by
// string literals, and a switch covering every member is exhaustive.
enum WS {
  INVALID = "invalid",
  INIT = "init",
  UPDATE = "update",
}

type Incoming =
  | { type: WS.INVALID }
  | { type: WS.INIT; payload: { a: number } }
  | { type: WS.UPDATE; payload: { b: string } };

export const bySwitch = (d: Incoming): number => {
  switch (d.type) {
    case WS.INVALID:
      return 0;
    case WS.INIT:
      return d.payload.a;
    case WS.UPDATE:
      return d.payload.b.length;
  }
};

export const byIf = (d: Incoming): number => {
  if (d.type === WS.INIT) {
    return d.payload.a;
  }
  if (d.type === WS.UPDATE) {
    return d.payload.b.length;
  }
  return 0;
};

// NEGATIVE: the wrong arm's payload after narrowing.
export const wrongArm = (d: Incoming) => {
  if (d.type === WS.INIT) {
    return d.payload.b;
  }
  return "";
};
// NEGATIVE: the arm with no payload at all.
export const noPayload = (d: Incoming) => {
  if (d.type === WS.INVALID) {
    return d.payload;
  }
  return 0;
};

// Narrowing a whole-enum reference: the true branch is the member, the false
// branch is every other member.
export function narrowWhole(x: WS) {
  if (x === WS.INIT) {
    const a: WS.INIT = x;
    const bad: WS.UPDATE = x;
  } else {
    const b: WS.INVALID | WS.UPDATE = x;
    const bad2: WS.INIT = x;
  }
}

// An exhaustive switch over a whole enum is terminal: no TS2366 here.
export function exhaustive(x: WS): number {
  switch (x) {
    case WS.INVALID:
      return 0;
    case WS.INIT:
      return 1;
    case WS.UPDATE:
      return 2;
  }
}

// NEGATIVE: one member missing -> the function can fall off the end.
export function notExhaustive(x: WS): number {
  switch (x) {
    case WS.INVALID:
      return 0;
    case WS.INIT:
      return 1;
  }
}
