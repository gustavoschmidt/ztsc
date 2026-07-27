export {};
// const enums, auto-increment numbering, an enum nested in a namespace, and
// the missing-member diagnostic.
const enum CE {
  X = "x",
  Y = "y",
}
enum Auto {
  Z, // 0
  O, // 1
  T = 10,
  E, // 11
}
namespace NS {
  export enum Inner {
    K = "k",
  }
}

declare const cx: CE.X;
declare const az: Auto.Z;
declare const ae: Auto.E;
declare const nk: NS.Inner.K;

// POSITIVE
const p1: "x" = cx;
const p2: CE = cx;
const p3: 0 = az;
const p4: 11 = ae;
const p5: Auto = ae;
const p6: "k" = nk;
const p7: NS.Inner = nk;
const p8: Auto.Z = 0;
const p9: Auto.E = 11;

// NEGATIVE
const n1: "y" = cx;
const n2: CE.Y = cx;
const n3: 1 = az;
const n4: 10 = ae;
const n5: Auto.O = az;
const n6: Auto.Z = 1;
const n7: NS.Inner.K = "k";
const n8: null = nk;

// NEGATIVE: a member that does not exist (TS2694).
declare const missing: CE.NOPE;
declare const missing2: NS.Inner.NOPE;
