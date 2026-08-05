// The negative control for `087_construct_signature_to_class_value.ts`: a
// class value target is still a real target.

class S {
  static make(): S {
    return new S();
  }
  s = 1;
}

// The source has the construct signature but not the static.
declare const noStatic: { new (...args: any[]): S };
export const n1: typeof S = noStatic;

// The source constructs the wrong instance type.
class T {
  t = 1;
}
declare const wrong: { new (...args: any[]): T; make(): S };
export const n2: typeof S = wrong;

// A plain object with no construct signature at all is rejected too, but the
// CODE is not pinned here: tsc's static side carries `prototype`, and a
// source with construct signatures gets one back from `NewableFunction`'s
// apparent members. ztsc models neither, so the two cancel for every source
// that constructs and differ only in which missing-property message a source
// that does not gets (tsc TS2741 on `prototype`, ztsc TS2322).
declare const plain: { make(): S };
export const n3 = plain as unknown as typeof S;

export {};
