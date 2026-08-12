// The parts of tsc's LEGACY decorator resolution ztsc does not do, each an
// under-report registered in DEFERRED. 010 is the part it does.
//
// Every group below is a shape the oracle rejects and ztsc accepts; none is a
// span or a code ztsc gets wrong. Kept executable so the day one of them is
// implemented, this case fails with a `-` entry that stopped describing
// reality.

// 1. An OVERLOAD SET where every candidate fails. tsc reports the LAST
//    candidate's argument error under a nested "No overload matches this
//    call." / "The last overload gave the following error." chain; ztsc
//    resolves only single-signature decorators.
declare function Overloaded(t: 1, k: unknown): void;
declare function Overloaded(t: 2, k: unknown): void;

// 2. A GENERIC decorator. tsc infers the type arguments from the synthesized
//    tuple and then judges the rest of the parameters against them; ztsc has
//    no inference on this path and accepts the signature outright.
declare function Generic<T>(t: T, k: 1): void;

// 3. A decorator that is NOT CALLABLE at all. tsc reports "This expression is
//    not callable." under the same TS1240 head.
declare const notCallable: { x: number };

// 4. A decorator FACTORY someone forgot to call. Every signature takes no
//    required argument and cannot absorb the ones the runtime passes, which
//    tsc reports as TS1329 ("Did you mean to call it first and write
//    '@Uncalled()'?") rather than as an arity failure. ztsc reports neither —
//    and the arity failure would be the WRONG one, so the shape is skipped
//    deliberately.
declare function Uncalled(opts?: { name: string }): void;

// 5. A UNION of decorator types. tsc relates the argument against the union's
//    combined call signature (its parameters intersected); ztsc only resolves
//    a function or a single-call-signature object.
declare const unioned: ((t: unknown, k: unknown) => void) | ((t: 1, k: unknown) => void);

// 6. The decorator's RETURN type — a SEPARATE family (TS1270/TS1271), not the
//    signature codes above: tsc requires `void` or `any` from a property or
//    parameter decorator, and the class or a descriptor from a class or method
//    one. ztsc checks only the call.
declare function ReturnsNumber(t: unknown, k: unknown): number;

// 7. PARAMETER decorators (TS1239). The parser discards a legacy parameter
//    decorator's expression instead of hanging it off the parameter, so there
//    is no node to check — see `parseParam`. 007_param_decorator covers the
//    same shapes with the flag OFF, where each is TS1206 instead.
declare function ParamLit(t: unknown, k: unknown, i: 999): void;

class Gaps {
  @Overloaded over!: string;
  @Generic gen!: string;
  @notCallable nc!: string;
  @Uncalled unc!: string;
  @unioned uni!: string;
  @ReturnsNumber ret!: string;

  method(@ParamLit a: number): void {}
  constructor(@ParamLit b: number) {}
}

export { Gaps };
