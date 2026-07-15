// A static field initializer that reads a sibling static — directly and
// from inside an arrow body — must resolve the sibling's real type without
// re-entering the in-progress member (which used to rebuild the whole class
// static object and stack-overflow). tsgo accepts all of these; the inferred
// types are real (number / string), not `any`, so the mismatches below are
// the only diagnostics.
class C {
  static base = 1;
  static viaArrow = () => C.base + 1; // () => number
  static viaDirect = C.base; // number
  static label = "n" + C.base; // string
}

const n: number = C.viaArrow();
const d: number = C.viaDirect;
const s: string = C.label;

// Proof the sibling types are real, not `any`: these must error.
const bad1: string = C.viaArrow(); // TS2322 number !-> string
const bad2: number = C.label; // TS2322 string !-> number
