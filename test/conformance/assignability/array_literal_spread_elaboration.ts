// tsc elaborates an array literal element-wise only when re-checking it with
// `forceTuple` yields a TUPLE-LIKE type (`elaborateArrayLiteral`). An array
// spread contributes a VARIADIC element, and `createNormalizedTupleType`
// collapses everything between the first and the last variadic into a single
// rest — so TWO array spreads normalize the literal to a plain array type,
// which is not tuple-like, and the whole literal is reported once at the
// assignment instead of once per offending element.
type Want = { a: number };
declare const bad: { a: string };
declare const arr: Want[];

// no spread: one error per offending element
const c1: Want[] = [
  bad,
  bad,
];

// two array spreads: one error, at the declaration
const c2: Want[] = [
  ...arr,
  bad,
  ...arr,
];

export { c1, c2 };
