// `T[K]` where `K` is an `infer` binder of an enclosing conditional. In tsc an
// `infer` binder IS a type parameter, so `isGenericIndexType` holds and the
// indexed access stays deferred until `getInferredType` substitutes the binder.
// ztsc models `infer` as its own kind, which the free-type-param test does not
// report, so `Form[infer K]` resolved eagerly — to `any` — and baked that in
// before the binder could be bound. Every case below therefore reported nothing.
//
// This is react-hook-form's `PathValueImpl` shape:
//   `P extends `${infer K}.${infer R}` ? K extends keyof T ? T[K] : … : …`

interface Form {
  name: string;
  owners: number[];
}

// Tuple-shaped binder, constrained inline.
type B1<T, P> = P extends [infer K extends keyof T] ? T[K] : "no";
declare const b1: B1<Form, ["owners"]>;
export const bb1: 1 = b1;

// Tuple-shaped binder, guarded by a nested conditional.
type B2<T, P> = P extends [infer K] ? (K extends keyof T ? T[K] : "nokey") : "no";
declare const b2: B2<Form, ["owners"]>;
export const bb2: 1 = b2;

// Template-literal binder — the dotted-path form.
type B3<T, P extends string> = P extends `${infer K}.${infer R}`
  ? K extends keyof T
    ? [T[K], R]
    : "nokey"
  : "nosplit";
declare const b3: B3<Form, "owners.0">;
export const bb3: 1 = b3;

// Distributive over `T` as well, one recursion level — the full path walk.
type B4<T, P extends string> = T extends any
  ? P extends `${infer K}.${infer R}`
    ? K extends keyof T
      ? B4<T[K], R>
      : K extends `${number}`
        ? T extends ReadonlyArray<infer U>
          ? B4<U, R>
          : never
        : never
    : P extends keyof T
      ? T[P]
      : never
  : never;
declare const b4: B4<Form, "owners.0">;
export const bb4: 1 = b4;

// NEGATIVE: a binder that is NOT a key of `T` still takes the false branch.
type B5<T, P> = P extends [infer K] ? (K extends keyof T ? T[K] : "nokey") : "no";
declare const b5: B5<Form, ["missing"]>;
export const bb5: "nokey" = b5;
