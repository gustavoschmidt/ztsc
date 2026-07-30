// Two rules React's `PropsWithRef` needs at once, on the shape that broke it.
//
// (1) An `infer` binder must read its property off an INTERSECTION source.
//     tsc's `inferFromProperties` uses `getTypeOfPropertyOfType`, and
//     `getUnionOrIntersectionProperty` synthesises an intersection's property
//     from the constituents that declare it, so `A & B` matches `{ ref?: infer
//     R | undefined }` whenever either constituent declares `ref`.
//
// (2) A conditional binds exactly the `infer V` DECLARATIONS in its own
//     extends clause. A NESTED conditional that merely mentions an enclosing
//     binder (`string extends R`) must not re-bind it — doing so bound
//     `R := string`, `Exclude<string, string>` is `never`, and the `ref` prop
//     collapsed to `undefined`.

interface Elem {
  tagName: string;
}
interface RefObject<T> {
  readonly current: T | null;
}
type Ref<T> = ((instance: T | null) => void) | RefObject<T> | null;
type LegacyRef<T> = string | Ref<T>;
interface RefAttributes<T> {
  ref?: LegacyRef<T> | undefined;
}
interface HtmlAttrs {
  id?: string | undefined;
}
// The intersection source: `ref` lives in one constituent only.
type Props = RefAttributes<Elem> & HtmlAttrs;

type PropsWithoutRef<P> = P extends any ? ("ref" extends keyof P ? Omit<P, "ref"> : P) : P;
type PropsWithRef<P> = "ref" extends keyof P
  ? P extends { ref?: infer R | undefined }
    ? string extends R
      ? PropsWithoutRef<P> & { ref?: Exclude<R, string> | undefined }
      : P
    : P
  : P;

// (1) The binder sees the intersection's `ref`, so `string` is one of its
// constituents and the outer guard takes its true branch.
type SawString = Props extends { ref?: infer R | undefined } ? (string extends R ? true : false) : false;
export const sawString: true = null as any as SawString;

// (2) The nested conditional left R alone, so the string ref is excluded and a
// real ref object survives.
declare const anchor: { current: Elem | null };
declare function take(p: PropsWithRef<Props>): void;
take({ ref: anchor });
take({ ref: (instance: Elem | null) => void instance });
take({ ref: null });
take({});

// A binder DECLARED by the nested conditional still binds normally.
type Head<T> = T extends [infer H, ...unknown[]] ? (H extends infer S ? S : never) : never;
export const head: "x" = null as any as Head<["x", 1]>;

// …and a binder the nested conditional only mentions is usable in its branches.
type FirstIfString<T> = T extends [infer H, ...unknown[]] ? (string extends H ? H : "narrow") : never;
export const narrow: "narrow" = null as any as FirstIfString<["x", 1]>;
export const wide: string = null as any as FirstIfString<[string, 1]>;
