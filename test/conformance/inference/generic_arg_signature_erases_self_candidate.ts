// A GENERIC FUNCTION passed as an argument has its own type parameters
// instantiated from the expected parameter types before the call infers
// through it. That instantiation is only sound when what it substitutes is
// real evidence: a candidate that MENTIONS one of the type parameters the
// call is still solving is not — substituted, it leaves the argument's
// signature naming the very variable being inferred, and the call then
// infers that variable from a type that contains itself.
//
// tsc never has the problem because it erases a generic argument
// signature's own parameters to their base constraints outright
// (`getBaseSignature`) before `inferFromSignatures`. So the guard is: erase
// when the candidate echoes an inference variable of THIS call. An
// enclosing function's parameter is an ordinary type here and must keep
// flowing.
//
// react-query is the shape: `placeholderData?: NonFunctionGuard<TQueryData>
// | PlaceholderDataFunction<NonFunctionGuard<TQueryData>>` against
// `keepPreviousData: <T>(prev: T | undefined) => T | undefined` gave `T` the
// CONDITIONAL `NonFunctionGuard<TQueryData>` as its candidate — not a bare
// parameter, but every bit as self-referential.

type NonFunctionGuard<T> = T extends Function ? never : T;
type PlaceholderFn<TQueryData> = (
  prev: TQueryData | undefined,
) => TQueryData | undefined;

interface Options<TQueryFnData> {
  queryFn: () => Promise<TQueryFnData>;
  placeholderData?:
    | NonFunctionGuard<TQueryFnData>
    | PlaceholderFn<NonFunctionGuard<TQueryFnData>>;
}

declare function useQ<TQueryFnData = unknown>(o: Options<TQueryFnData>): {
  data: TQueryFnData;
};

declare function keepPrevious<T>(prev: T | undefined): T | undefined;
declare const source: {profiles: {did: string}[]};

// `queryFn` is the only real evidence; the generic argument must not
// overrule it with a candidate spelled in terms of `TQueryFnData`.
export function withGenericPlaceholder() {
  const {data} = useQ({
    queryFn: async () => source,
    placeholderData: keepPrevious,
  });
  const n: number = data.profiles.length;
  return n;
}

// The same call without the generic argument, as the control.
export function withoutPlaceholder() {
  const {data} = useQ({queryFn: async () => source});
  const n: number = data.profiles.length;
  return n;
}

// An ENCLOSING function's parameter is not one of THIS call's variables, so
// a candidate naming it is ordinary evidence and still flows: the expected
// parameter type here is concrete, and the generic argument's own `A` takes
// the outer `T` from it rather than being erased.
declare function runOn<R>(x: unknown, f: (e: {tag: string}) => R): R;
declare function widen<A extends {tag: string}>(a: A): A[];
export function outer<T extends {tag: string}>(x: T) {
  const rows: {tag: string}[] = runOn(x, widen);
  return rows;
}

// A concrete expected parameter type still instantiates the argument's own
// parameters, so its RETURN contributes the real type (nothing here echoes
// an inference variable).
declare function runThen<R>(f: (input: {id: string}) => R): R;
declare function pick<A extends {id: string}>(a: A): A;
export const picked: {id: string} = runThen(pick);
export const pickedWrong: number = runThen(pick);
