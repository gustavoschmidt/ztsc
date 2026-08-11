// `strictPropertyInitialization` (TS2564), declaration side: which property
// declarations the check even looks at. tsc's `checkPropertyInitialization`
// walks the members of a non-ambient class and judges each one that
// `isPropertyWithoutInitializer` accepts — no initializer, no `!`, not
// `abstract` — and that is not `static`, not `declare`, and whose type is
// neither `any`/`unknown` nor a union containing `undefined`. The name must be
// an identifier, a private name or a computed name, so a QUOTED or numeric
// member name is skipped outright.
//
// The diagnostic sits on the property NAME, not on the first modifier.

export class Reported {
  plain: string;
  private priv: string;
  protected prot: string;
  public pub: string;
  readonly ro: string;
  override?: never; // (not a modifier here — a property called `override`)
  #hash: string;
  nul: null;
  vd: void;
  nev: never;
  fn: () => void;
  arr: string[];
  gen: Map<string, number>;
}

export class Exempt {
  withInit = "";
  definite!: string;
  optional?: string;
  orUndefined: string | undefined;
  anyTyped: any;
  unknownTyped: unknown;
  undefinedTyped: undefined;
  static staticField: string;
  declare declared: string;
  "quoted": string;
  1: string;
  get accessorLike(): string {
    return "";
  }
  set accessorLike(v: string) {}
  method(): void {}
}

export abstract class WithAbstract {
  abstract abs: string;
  concrete: string;
  abstract get absGet(): string;
}

// A generic parameter is not `any` and does not contain `undefined`.
export class Generic<T, U = string> {
  t: T;
  maybeT: T | undefined;
  u: U;
}

// A class expression and a class declared inside a function are checked the
// same way.
export const Expr = class {
  inExpr: string;
};

export function inFunction() {
  class Local {
    x: string;
  }
  return Local;
}

// An index signature is not a property declaration.
export class Indexed {
  [k: string]: string | undefined;
  named: string;
}
