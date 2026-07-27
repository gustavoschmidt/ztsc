// `infer` over a CONSTRUCT-signature pattern must match a class value
// (`typeof C`). A `.class_value` is nominal — `new C()` and `C.staticMember`
// read it directly, so it carries no structural construct signature; the
// `InstanceType<T> = T extends abstract new (...args: any) => infer R ? R :
// never` pattern therefore never bound `R` and the whole conditional collapsed
// to `unknown` (every member access on it became TS2339).
type Inst<T> = T extends abstract new (...args: any) => infer R ? R : never;
type NewInst<T> = T extends new (...args: any) => infer R ? R : never;
type CtorArgs<T> = T extends abstract new (...args: infer A) => any ? A : never;

class C {
  x: number = 1;
  m(): string {
    return 'a';
  }
  static s: boolean = true;
}

declare const i: Inst<typeof C>;
const a: number = i.x;
const b: string = i.m();
const aBad: string = i.x; // TS2322

declare const j: NewInst<typeof C>;
const c1: number = j.x;

// A declared constructor: parameters come through too.
class D {
  constructor(
    public n: number,
    s: string,
  ) {}
}
declare const d: Inst<typeof D>;
const e1: number = d.n;
declare const args: CtorArgs<typeof D>;
const e2: number = args[0];
const e3: string = args[1];
const e4: boolean = args[0]; // TS2322

// A class with no declared constructor still matches (implicit `new () => C`).
declare const noArgs: CtorArgs<typeof C>;
const e5: [] = noArgs;

// Statics are on the constructor object, not the instance.
declare const st: Inst<typeof C>;
const e6: boolean = st.s; // TS2576
