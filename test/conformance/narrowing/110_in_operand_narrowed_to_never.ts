// `never` is not a primitive for the `in` operand test: tsc asks
// `allTypesAssignableToKind(rightType, NonPrimitive | InstantiableNonPrimitive)`
// and `never` is assignable to everything, so no TS2361.
interface Klass {
  new (p: unknown): { render(): unknown };
}
type Fn = (p: unknown) => unknown;

declare const icon: Klass | Fn;

function render() {
  // The FALSE branch of `typeof icon === 'function'` drops both callable
  // constituents, so the second disjunct sees `never`.
  if (typeof icon === "function" || (typeof icon === "object" && icon && "render" in icon)) {
    return 1;
  }
  return 0;
}

// An object operand is still fine, and the guard still narrows.
declare const o: { a: number } | { b: string };
function pick() {
  if ("a" in o) {
    return o.a;
  }
  return o.b;
}
declare const bad: string;
const badRead: number = pick();
const stillNarrows: string = "a" in o ? o.a : o.b; // TS2322: number is not string
