// tsc's `inferToConditionalType` hands a conditional TARGET to
// `inferToMultipleTypes` as `[trueType, falseType]`, and that routine gives
// a branch which is a NAKED type variable `InferencePriority.
// NakedTypeVariable`: "inferences directly to naked type variables are
// given lower priority as they are less specific". Only the best priority
// seen is kept, so any candidate an ordinary position supplies REPLACES
// what the branch offers, in either arrival order.
//
// The priority has to hold inside the two-round context-sensitive probe as
// well. That round infers this same call into a scratch accumulator, and
// its answer is what pins every context-sensitive callback's parameter
// types for the authoritative pass — so a candidate admitted at full
// priority there fixes the parameter before the real pass can correct it.
//
// react-query's `initialData?: undefined | NonUndefinedGuard<TQueryFnData> |
// (() => NonUndefinedGuard<TQueryFnData> | undefined)` is the shape: every
// candidate that property can offer reaches the query's data type only
// through a conditional's branch, and at full priority the whole
// `initialData` union became the data type — so `select`'s parameter, and
// every read off the result, was that union instead of the queried value.

type NonUndefinedGuard<T> = T extends undefined ? never : T;
type InitialData<T> =
  | undefined
  | NonUndefinedGuard<T>
  | (() => NonUndefinedGuard<T> | undefined);

declare function useQ<T = unknown>(o: {
  queryFn: () => Promise<T>;
  initialData?: InitialData<T>;
  select?: (d: T) => number;
}): {data: T};

declare const initial: string | (() => string | undefined) | undefined;

// One round: no context-sensitive property.
export const oneRound: string = useQ({
  queryFn: async () => 'hi',
  initialData: initial,
}).data;

// Two rounds: `select` is context sensitive, so the probe round decides
// what `d` is typed as.
export const twoRounds = useQ({
  queryFn: async () => 'hi',
  initialData: initial,
  select: (d) => d.length,
}).data;
export const twoRoundsData: string = twoRounds;

// The conditional's branch is still the ONLY evidence here, so it must
// still be recorded — lower priority is not "discarded".
declare function onlyBranch<T>(x: NonUndefinedGuard<T>): T;
export const soleCandidate: string = onlyBranch('hi');

// Arrival order must not matter: the low-priority property written FIRST
// is replaced by the direct one written second.
export const reversed: string = useQ({
  initialData: initial,
  queryFn: async () => 'hi',
}).data;
