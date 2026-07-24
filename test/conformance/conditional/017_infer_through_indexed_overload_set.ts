// A conditional-type `infer` through a plain overload set — the type of a
// multiply-declared method reached by property/indexed access (`S['m']`) — must
// align to the LAST call signature (tsc's `inferFromSignatures`), so
// `ReturnType<S['m']>` reads the last overload's return instead of collapsing to
// `unknown`. Mirrors jest's `jest.Mocked<Service>` where `Service.patch` has two
// overloads and `mockResolvedValueOnce(value: ResolvedValue<ReturnType<...>>)`
// must accept `null` (the return is a Promise, not `unknown`).
interface S2 {
  m(p: string): Promise<string>;
  m(p: string, d: number): Promise<boolean>;
}
type RT = ReturnType<S2["m"]>;
// last overload return is Promise<boolean>
const ok: Promise<boolean> = null as unknown as RT;
// negative control: it is NOT unknown, so a plain string is not assignable
const bad: string = null as unknown as RT;

// generic overloaded method (jest's Service.patch shape)
interface Svc {
  patch<P, R>(path: string, data?: P): Promise<{ ok: R }>;
  patch<P>(path: string, data?: P): Promise<P>;
}
type ResolvedValue<T> = T extends PromiseLike<infer U> ? U | T : never;
declare function want(v: ResolvedValue<ReturnType<Svc["patch"]>>): void;
want(null); // ResolvedValue<Promise<unknown>> = unknown; null OK
