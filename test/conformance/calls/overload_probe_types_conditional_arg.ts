// tsc's `checkApplicableSignature` contextually types EVERY argument by the
// candidate's parameter (`checkExpressionWithContextualType`), and a
// conditional expression forwards that contextual type into both of its
// branches. Probed context-free instead, an object literal in a branch widens
// its discriminant to `string`, so no candidate accepts it and the call falls
// out TS2769 — while the single-signature form of the same call, which is
// checked directly against the parameter, is accepted.
//
// React's `useState<S>(initialState: S | (() => S))` / `useState<S =
// undefined>()` pair is the shape social-app trips on.

type SetStateAction<S> = S | ((prev: S) => S);
type Dispatch<A> = (value: A) => void;

declare function useState<S>(
  initialState: S | (() => S),
): [S, Dispatch<SetStateAction<S>>];
declare function useState<S = undefined>(): [
  S | undefined,
  Dispatch<SetStateAction<S | undefined>>,
];

type MessageEmbedState =
  | { type: "post"; uri: string }
  | { type: "invite"; code: string };

declare const embedFromParams: string | undefined;

const [embed, setEmbed] = useState<MessageEmbedState | undefined>(
  embedFromParams ? { type: "post", uri: embedFromParams } : undefined,
);

// Both branches are contextually typed, so a discriminated pair resolves too.
declare const flag: boolean;
declare function pick<S>(x: S): S;
declare function pick<S = undefined>(): S | undefined;
const both = pick<MessageEmbedState>(
  flag ? { type: "post", uri: "u" } : { type: "invite", code: "c" },
);

// Non-generic overloads take the same path.
declare function plain(x: MessageEmbedState | undefined): void;
declare function plain(): void;
plain(flag ? { type: "post", uri: "u" } : undefined);

// Negative: the contextual type does not excuse a branch that does not fit —
// an unknown discriminant is still rejected, and a real excess property on a
// fresh literal in a branch is still excess. (Spelled on a single signature:
// the code and position an OVERLOAD set reports these under is tsc's
// candidate-count rule in `resolveCall`, which ztsc does not mirror yet — it
// always reports TS2769, anchored at the last candidate's first argument
// diagnostic.)
declare function only<S>(x: S): S;
const bad1 = only<MessageEmbedState>(
  flag ? { type: "nope", uri: "u" } : { type: "invite", code: "c" },
);
const bad2 = only<MessageEmbedState>({ type: "post", uri: "u", extra: 1 });

export { embed, setEmbed, both, bad1, bad2 };
