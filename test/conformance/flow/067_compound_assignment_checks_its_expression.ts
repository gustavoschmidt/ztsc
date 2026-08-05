// A compound assignment's post-value is the whole expression's type
// (`x ??= s` leaves `NonNullable<x> | typeof s`), and `assignNarrows` read it
// opportunistically out of the node cache, falling back to the DECLARED type
// when the assignment statement had not been checked yet. `flowType` memoizes
// a result equal to `declared` as "this reference narrows nothing", so the
// non-answer was then published for every later query at that flow node — the
// narrowing was lost for the whole function.
//
// A later reference in the same function is enough to provoke it: its type is
// demanded first (through the inferred return type), its walk reaches the
// assignment before the statement is checked, and the earlier reference then
// reads the poisoned entry. immich's `OAuthRepository.authorize` is exactly
// this shape — `state ??= randomState()` and `state` in both the params
// object and the returned object.

interface Strings {
  [k: string]: string;
}

declare function randomState(): string;

// The annotated use comes FIRST, so it is the one that reads the memo.
export function annotatedUseFirst(state?: string) {
  state ??= randomState();
  const params: Strings = { state };
  const later = state;
  return { params, later };
}

// ... and the other order, which never lost it (the plain read populated the
// memo correctly before the object literal asked).
export function annotatedUseSecond(state?: string) {
  state ??= randomState();
  const later = state;
  const params: Strings = { state };
  return { params, later };
}

// A statement boundary between the assignment and the use does not save it:
// the poisoned entry is the assignment's own flow node.
export function acrossABranch(flag: boolean, state?: string) {
  state ??= randomState();
  if (flag) {
    const params: Strings = { state };
    return params;
  }
  const later = state;
  return { later };
}

// `||=` and `&&=` take the same arm.
export function orAssign(state?: string) {
  state ||= randomState();
  const params: Strings = { state };
  const later = state;
  return { params, later };
}

export function andAssign(state: string | null) {
  state &&= randomState();
  const kept: string | null = state;
  const later = state;
  return { kept, later };
}

// A class method, where the member table's return-type demand is what asks
// first.
export class Repo {
  authorize(state?: string) {
    state ??= randomState();
    const params: Strings = { state };
    return { params, state };
  }
}

// A compound assignment writes a PATH exactly as it writes a variable, and
// the path arm gave up outright — `session.startSegment ??= i` left it
// `number | null` for the rest of the function (immich's
// `TranscodingService.onSegmentRequest`).
interface Session {
  lastCompletedSegment: number | null;
  startSegment: number | null;
  variantIndex: number | null;
}

export function pathCompoundNarrows(session: Session, variantIndex: number, segmentIndex: number) {
  session.variantIndex ??= variantIndex;
  session.startSegment ??= segmentIndex;
  const curSegment = session.lastCompletedSegment === null ? session.startSegment : session.lastCompletedSegment + 1;
  return session.variantIndex !== variantIndex || segmentIndex < session.startSegment || segmentIndex > curSegment + 1;
}

// Negative control: a SIBLING path's compound write narrows nothing here.
export function siblingPathIsUntouched(session: Session) {
  session.startSegment ??= 0;
  const wrong: number = session.lastCompletedSegment;
  return wrong;
}

// Negative control: with no assignment at all the optional parameter still
// fails the same annotated use.
export function noAssignmentStillFails(state?: string) {
  const params: Strings = { state };
  const later = state;
  return { params, later };
}

// Negative control: a compound assignment that cannot refine still reports.
// `n += 1` leaves a `number`, so the `string` annotation is still wrong.
export function compoundKeepsItsOwnType(n: number) {
  n += 1;
  const wrong: string = n;
  const later = n;
  return { wrong, later };
}
