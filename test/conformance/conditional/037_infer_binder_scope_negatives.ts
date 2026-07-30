// Negatives for 036: the inferred binder and the `ref` prop it builds have
// exactly one shape, and assigning them to `number` prints it. A regression in
// either rule changes the printed type, so the snapshot pins both.
//
// Also pins what must STILL be rejected: the string ref is excluded from the
// rebuilt prop, and the binder is not silently widened to `unknown`.

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
type Props = RefAttributes<Elem> & HtmlAttrs;

type PropsWithoutRef<P> = P extends any ? ("ref" extends keyof P ? Omit<P, "ref"> : P) : P;
type PropsWithRef<P> = "ref" extends keyof P
  ? P extends { ref?: infer R | undefined }
    ? string extends R
      ? PropsWithoutRef<P> & { ref?: Exclude<R, string> | undefined }
      : P
    : P
  : P;

// The binder read off the INTERSECTION source (not `unknown`).
type Inferred = Props extends { ref?: infer R | undefined } ? R : "NOMATCH";
export const a: number = null as any as Inferred;

// The rebuilt `ref` prop (not `undefined`).
export const b: number = (null as any as PropsWithRef<Props>)["ref"];

// `Exclude` still removes the string ref.
export const legacy: PropsWithRef<Props>["ref"] = "legacy";

// A property the intersection does not declare infers nothing.
type Missing = Props extends { nope?: infer R | undefined } ? R : "NOMATCH";
export const c: number = null as any as Missing;
