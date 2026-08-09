// tsc's `narrowTypeByEquality` subtracts on the NOT-EQUAL side only when the
// COMPARAND is a unit type:
//
//     if (!assumeTrue) {
//       if (valueType.flags & TypeFlags.Unit) return filterType(type, …);
//       return type;
//     }
//
// A comparand that is a whole ENUM — or any union of units — carries no Unit
// flag, so nothing is subtracted. Filtering on comparability alone removed
// every constituent whose discriminant the comparand could equal, which for
// a whole-enum comparand is all of them.

export enum ConvoStatus {
  Uninitialized = "uninitialized",
  Initializing = "initializing",
  Ready = "ready",
  Error = "error",
}

type ConvoState =
  | { status: ConvoStatus.Uninitialized; a: 1 }
  | { status: ConvoStatus.Initializing; b: 2 }
  | { status: ConvoStatus.Ready; c: 3 }
  | { status: ConvoStatus.Error; d: 4 };

declare const convoState: ConvoState;
declare const prevState: ConvoStatus;

// `prevState` is the whole enum, so this subtracts nothing.
export function keepsEverything(): number {
  if (prevState !== convoState.status) {
    if (convoState.status === ConvoStatus.Initializing) return convoState.b;
    if (convoState.status === ConvoStatus.Ready) return convoState.c;
  }
  return 0;
}

// A union-of-literals comparand behaves the same way.
declare const someOf: ConvoStatus.Ready | ConvoStatus.Error;
export function unionComparand(): number {
  if (someOf !== convoState.status) {
    if (convoState.status === ConvoStatus.Ready) return convoState.c;
  }
  return 0;
}

// A UNIT comparand still subtracts, on both sides.
export function unitStillNarrows(): number {
  if (convoState.status !== ConvoStatus.Uninitialized) {
    const rest:
      | { status: ConvoStatus.Initializing; b: 2 }
      | { status: ConvoStatus.Ready; c: 3 }
      | { status: ConvoStatus.Error; d: 4 } = convoState;
    return rest.status === ConvoStatus.Ready ? rest.c : 0;
  }
  return convoState.a;
}

// NEGATIVES — nothing was subtracted, so the other constituents' own
// properties are still not there.
export function bad1(): number {
  if (prevState !== convoState.status) {
    return convoState.b;
  }
  return 0;
}

export function bad2(): number {
  if (convoState.status !== ConvoStatus.Uninitialized) {
    return convoState.a;
  }
  return 0;
}
