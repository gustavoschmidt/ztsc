// tsc runs a generic call's inference in TWO rounds when some argument is
// CONTEXT SENSITIVE (`resolveCall` sets `CheckMode.SkipContextSensitive`,
// `chooseOverload` clears it for a second `inferTypeArguments`).
//
// Round one types every context-sensitive function expression as
// `anyFunctionType` — a placeholder with `ObjectFlags.NonInferrableType`,
// which `inferFromTypes` refuses as a source. An object literal that carries
// one propagates the flag, so the literal cannot be inferred whole either.
// What round one learns therefore comes only from the argument's
// INSENSITIVE parts, and the type parameters a callback would have
// determined stay open.
//
// Round two re-checks the argument with those inferences substituted. A
// callback's parameter types come from
// `instantiateSignature(contextualSignature, inferenceContext.mapper)` — the
// FIXING mapper — so every type parameter the contextual signature names in
// a PARAMETER position is pinned and records no further candidate. A
// parameter named only in the contextual RETURN is not: `instantiateSignature`
// resolves the return lazily, so the fixing mapper never reaches it.

// react-query's `useQuery` -----------------------------------------------
type NonFunctionGuard<T> = T extends Function ? never : T;
type PlaceholderFn<TQueryData> = (
  prev: TQueryData | undefined,
) => TQueryData | undefined;

interface QueryOptions<TQueryFnData, TData = TQueryFnData> {
  queryKey: unknown[];
  queryFn: () => Promise<TQueryFnData>;
  placeholderData?:
    | NonFunctionGuard<TData>
    | PlaceholderFn<NonFunctionGuard<TData>>;
}
declare function useQuery<TQueryFnData, TData = TQueryFnData>(
  o: QueryOptions<TQueryFnData, TData>,
): { data: TData };

type Item = { uri: string };
declare const items: Item[];

// `placeholderData` names `TData` in a PARAMETER, so it contributes nothing
// and `TData` keeps its default — `TQueryFnData`, which `queryFn` supplied.
// Read context-free in round one, the fallback's `feeds: []` would have made
// it `any[]`.
const q1 = useQuery({
  queryKey: ["k"],
  queryFn: async () => ({ count: 1, feeds: items }),
  placeholderData: (prev) => prev || { count: 0, feeds: [] },
});
export const uri1: string = q1.data.feeds[0].uri;

// The pass-through form is the same rule: still no candidate from
// `placeholderData`.
const q2 = useQuery({
  queryKey: ["k"],
  queryFn: async () => ({ count: 1, feeds: items }),
  placeholderData: (prev) => prev,
});
export const uri2: string = q2.data.feeds[0].uri;

// Property order is irrelevant.
const q3 = useQuery({
  queryKey: ["k"],
  placeholderData: (prev) => prev || { count: 0, feeds: [] },
  queryFn: async () => ({ count: 1, feeds: items }),
});
export const uri3: string = q3.data.feeds[0].uri;

// react-query's `useMutation` --------------------------------------------
interface MutOptions<TData, TVars, TContext> {
  mutationFn: (vars: TVars) => Promise<TData>;
  onMutate?: (
    vars: TVars,
  ) => Promise<TContext | undefined> | TContext | undefined;
  onSuccess?: (data: TData, vars: TVars, ctx: TContext | undefined) => unknown;
}
declare function useMutation<TData, TVars, TContext = unknown>(
  o: MutOptions<TData, TVars, TContext>,
): { ctx: TContext };

// `onMutate` names `TContext` only in its RETURN, so it is NOT fixed and
// still determines it — even though `onSuccess` echoes it back through a
// parameter.
const m = useMutation({
  mutationFn: async ({ id }: { id: string }) => ({ ok: id }),
  onMutate: async (_v) => ({ snapshot: 1 }),
  onSuccess: (_d, _v, _ctx) => {},
});
export const snap: number = m.ctx.snapshot;

// And the callback that NAMES it in a parameter is handed the real thing,
// not the value round one stopped at. `onMutate` is context sensitive, so
// round one — which skips it — leaves `TContext` open; the parameter is
// fixed at what the properties BEFORE it have contributed, which by then
// includes `onMutate`'s return. The pass that types this body is the
// authoritative one, so getting it wrong is a reported error, not a
// provisional reading something later corrects.
export function ctxIsReal() {
  let out = 0;
  useMutation({
    mutationFn: async ({ id }: { id: string }) => ({ ok: id }),
    onMutate: async (_v) => ({ snapshot: 1 }),
    onSuccess: (_d, _v, ctx) => {
      out = ctx ? ctx.snapshot : 0;
    },
  });
  return out;
}

// NEGATIVE -----------------------------------------------------------------

// The callback parameter really is the inferred type, so a wrong use is
// caught rather than swallowed.
const q5 = useQuery({
  queryKey: ["k"],
  queryFn: async () => ({ count: 1, feeds: items }),
  placeholderData: (prev) => {
    const n: number = prev; // TS2322
    void n;
    return prev;
  },
});
export const uri5: string = q5.data.feeds[0].uri;
