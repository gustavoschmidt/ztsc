// A homomorphic mapped type (`Partial`) reduces over its source's KEYS alone —
// never deferring on the source's VALUE types. This is the reduction at the
// core of a real form library's `FieldErrors<Form>`:
//   Partial<… ? any : Impl<DeepReq<T>>> & { root?; form? }
// where `Impl`'s per-key value is a recursive `Merge<…>` conditional. Those
// value branches stay generic (they carry the merge's own type params) long
// after the KEY set — `keyof DeepReq<Form>` — is fully concrete. The homomorphic
// `Partial` must still materialize `Form`'s keys; deferring on the value branches
// stranded it as `{ [P in keyof {…}]: … }` and dropped every member, so
// `errors.<field>` collapsed to the intersection's `{ root?; form? }` half alone
// (spurious TS2339 on every real field). The negative control — a key that is
// NOT in the form — must still error.
type FieldValues = Record<string, any>;
type Message = string;
type Merge<A, B> = {
  [K in keyof A | keyof B]?: K extends keyof A & keyof B
    ? [A[K], B[K]] extends [object, object] ? Merge<A[K], B[K]> : B[K]
    : K extends keyof A ? A[K] : K extends keyof B ? B[K] : never;
};
type Leaf = { type: string; message?: Message };
type DeepReq<T> = T extends Date ? T : { [K in keyof T]-?: NonNullable<DeepReq<T[K]>> };
type Impl<T extends FieldValues = FieldValues> = {
  [K in keyof T]?: T[K] extends Date ? Leaf
    : K extends 'root' | `root.${string}` ? GlobalError
    : T[K] extends object ? Merge<Leaf, Impl<T[K]>>
    : Leaf;
};
type GlobalError = Partial<{ type: string | number; message: Message }>;
type Wrapped<T extends FieldValues = FieldValues> = Partial<Impl<DeepReq<T>>> & {
  root?: Record<string, GlobalError> & GlobalError;
  form?: GlobalError;
};

interface Form { email: string; nested: { deep: string } }
declare const errors: Wrapped<Form>;
const a = errors.email;       // ok — key materialized despite deferred value
const b = errors.nested;      // ok — nested field key too
const c = errors.nope;        // TS2339 — negative control, not a member of Form

export {};
