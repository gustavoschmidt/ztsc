// TS2415 / TS2416 and the order they are decided in.
//
// tsc relates the derived INSTANCE type to the base instance type at the
// declaration and, when that fails, re-reports per member
// (`issueMemberSpecificError`): every own instance member the base ALSO
// declares and whose type does not relate gets its own TS2416, and only when
// no member could be blamed does the broad TS2415 fire once on the class name.
// The STATIC side (TS2417) is checked only when the instance side passed.

// ---------------------------------------------------------------- TS2416
// Two members redeclared incompatibly: two reports, one per member, at the
// member NAME, in source order.
class Base {
  a = 1;
  b = "";
  c = true;
  m(): number {
    return 1;
  }
}

class TwoBad extends Base {
  declare a: string;
  declare b: number;
  declare c: boolean; // same type: no report
}

// A METHOD redeclared as an incompatible method is compared bivariantly, so
// this pair still relates and nothing is reported.
class MethodOk extends Base {
  m(): 1 {
    return 1;
  }
}

// ---------------------------------------------------------------- TS2415
// The clashing member is declared by a CONSTRUCTOR PARAMETER PROPERTY, which
// is not a member node, so tsc's walk over `node.members` finds nothing to
// blame and falls back to the broad diagnostic on the class name. (Walking the
// member *scope* instead would find `a` and report TS2416 here.)
class ParamPropBase {
  a = 1;
}
class ParamProp extends ParamPropBase {
  constructor(public a: string) {
    super();
  }
}

// ---------------------------------------------------------------- TS2417
// The static side is reported only when the instance side is fine. Here it is:
// only the static shadows incompatibly.
class StaticBase {
  static s = 1;
  ok = 1;
}
class StaticOnly extends StaticBase {
  static s = "";
}

// …and here it is not, so the member error is the only one: the static clash
// on the same class is NOT also reported.
class BothBad extends StaticBase {
  static s = "";
  declare ok: string;
}

// ---------------------------------------------------------------- controls
// Adding members is always fine, and so is redeclaring at the same type.
class AddsOnly extends Base {
  extra = 0;
}
class Same extends Base {
  declare a: number;
}

export type Keep = [TwoBad, MethodOk, ParamProp, StaticOnly, BothBad, AddsOnly, Same];
