// tsc's `getInferredType` weighs the covariant inference against the
// contravariant candidate LIST, not against their fold:
//
//     const useCovariantType = inferredCovariantType &&
//       !(inferredCovariantType.flags & TypeFlags.Never) &&
//       some(inference.contraCandidates, t => isTypeSubtypeOf(inferredCovariantType, t)) && …;
//     inferredType = useCovariantType ? inferredCovariantType
//                                     : getContravariantInference(inference);
//
// ONE parameter position that still accepts the covariant answer is enough.
// And a CONTEXT-SENSITIVE callback contributes no contravariant evidence at
// all: its parameter types are the contextual type the inference engine just
// handed it, and reading a variable for that contextual type memoizes
// `inference.inferredType` — nothing short of fixing reopens it.
//
// react-native-reanimated's `useAnimatedReaction` is the shape that needs
// both. `prepared: P` yields the candidate `string | null` and
// `previous: P | null` yields `string` (union subtraction); their common
// subtype is `string`, which rejected the covariant `string | null` that
// `() => hoveredItemSV.get()` supplies — TS2322 on the FIRST argument.

declare const sv: {get(): string | null};

declare function useAnimatedReaction<P>(
  prepare: () => P,
  react: (prepared: P, previous: P | null) => void,
): void;

// Un-annotated callback: context sensitive, so it is not evidence at all.
useAnimatedReaction(
  () => sv.get(),
  (hovered, prev) => {
    const a: string | null = hovered;
    const b: string | null = prev;
  },
);

// Annotated callback: real contravariant evidence, but `prepared: P` accepts
// `string | null`, so `some(...)` holds and the covariant answer stands.
useAnimatedReaction(
  () => sv.get(),
  (a: string | null, b: string | null) => {},
);

// Only the `P | null` position, un-annotated — still no evidence.
declare function f6<P>(prepare: () => P, react: (previous: P | null) => void): void;
f6(
  () => sv.get(),
  b => {
    const x: string | null = b;
  },
);

// --- what must still report -------------------------------------------------
// A NON-context-sensitive argument carries genuine contravariant evidence, and
// `(p: string | null) => void` is the only position, so the contravariant
// inference `string` wins and the first argument no longer fits.
declare function f7<P>(prepare: () => P, sink: (p: P | null) => void): void;
declare const sink: (p: string | null) => void;
f7(() => sv.get(), sink);
