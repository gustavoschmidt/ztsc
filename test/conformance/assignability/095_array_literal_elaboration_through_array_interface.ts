// tsc's `elaborateArrayLiteral` reports an array-literal mismatch ELEMENT BY
// ELEMENT, at the offending element's own node — it bails only on a PRIMITIVE
// target. The element's target comes from
// `getBestMatchIndexedAccessTypeOrUndefined(source, target, numberLiteral(i))`,
// i.e. `getIndexedAccessTypeOrUndefined`, which reads a NUMERIC INDEX
// SIGNATURE — so an interface that merely DERIVES from `Array` is indexable
// there just like `T[]` is.
//
// react-native's `StyleProp<T>` is exactly that shape
// (`RecursiveArray<T> extends Array<T | ReadonlyArray<T> | RecursiveArray<T>>`),
// and an array reported whole instead of per element lands on a line no
// `@ts-ignore` above the offending element covers. Every array below spreads
// its elements over their own lines so the snapshot pins WHICH node is blamed.

interface RecursiveArray<T>
  extends Array<T | ReadonlyArray<T> | RecursiveArray<T>> {}

// Directly against the Array-derived interface: the blame is on the element.
const a: RecursiveArray<number> = [
  1,
  'a',
  2,
];

// Nested one level.
interface Nest<T> extends Array<T> {}
const b: Nest<number> = [
  1,
  'a',
];

// Through a UNION target, where the Array-derived constituent is the one
// tsc's `getBestMatchingType` picks (its `keyof` overlaps the source array's
// on every `Array` member, while the object arm overlaps on none).
interface Style {
  padding: number;
}
type Falsy = false | '' | null | undefined;
type StyleProp<T> = T | RecursiveArray<T | Falsy> | Falsy;
declare const bad: {padding: string};
const c: StyleProp<Style> = [
  {padding: 1},
  bad,
  false,
];

// `elaborateArrayLiteral` bails on a PRIMITIVE target, so this one is still
// reported whole, at the assignment.
const d: string = [
  1,
  2,
];
