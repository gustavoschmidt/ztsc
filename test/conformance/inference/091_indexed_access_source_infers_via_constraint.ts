// The apparent-source rule (see 081) covers every INSTANTIABLE source, not
// only a bare type variable: tsc's `getApparentType` reduces an indexed access
// and a conditional the same way.
//
// A parameter typed `T["boundElements"]` contributes through its base
// constraint, which is what gives the array literal written for it a real
// contextual type — without it the callback's `type: "arrow"` had none and
// widened to `string`.

type Bound = { type: "arrow" | "text"; id: string };
interface Base {
  boundElements: readonly Bound[] | null;
  kind: "a" | "b";
}

declare const ids: string[];
declare function want<T extends Base>(x: T["boundElements"]): void;

export function useWant<T extends Base>() {
  want<T>(ids.map((id) => ({ type: "arrow", id })));
}

// The same through an aliased indexed access.
type BE<T extends Base> = T["boundElements"];
declare function want2<T extends Base>(x: BE<T>): void;
export function useWant2<T extends Base>() {
  want2<T>(ids.map((id) => ({ type: "text", id })));
}

// A concrete indexed access was never deferred and is unchanged.
declare function want3(x: Base["boundElements"]): void;
export function useWant3() {
  want3(ids.map((id) => ({ type: "arrow", id })));
}
