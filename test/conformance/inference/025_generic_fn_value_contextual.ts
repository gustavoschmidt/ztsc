// A generic function VALUE passed as a callback is contextually
// instantiated against the expected signature (its own T binds from the
// expected parameter types, so the return contributes concretely).
interface PR { name?: string; id: string }
declare function transform<T = PR>({ data }: { data: T }): T;
declare function get(): Promise<{ data: PR }>;
function getProject(): Promise<PR> {
  return get().then(transform);
}
// Inference from an `any` source binds any (not nothing).
declare const anyArr: Promise<any>[];
const r = Promise.all(anyArr).then((res) => res[0]);
const ok: Promise<number> = r;
