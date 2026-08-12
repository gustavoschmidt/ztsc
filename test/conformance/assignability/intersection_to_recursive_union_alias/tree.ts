// A UNION alias in a CYCLE: `Variant` names `Branch`, and `Branch`'s `children`
// names `Variant` again. Whichever end of that cycle is resolved first, the
// other is reached while still resolving and is spelled as an unexpanded lazy
// reference — so `Variant` survives as a bare REF *member* of the element union
// `(Variant | Group | Sep)`, and every one of its own constituents is an
// INTERSECTION.
//
// This is outline's action tree (`app/types.ts`) reduced: `ActionVariant =
// Action | InternalLinkAction | … | ActionWithChildren`, where
// `ActionWithChildren` spells `children: ((c) => (ActionVariant | ActionGroup |
// ActionSeparator)[]) | (ActionVariant | ActionGroup | ActionSeparator)[]` and
// every variant is `BaseAction & { … }`.
export type BaseNode = { kind: "node"; id: string };

export type Leaf = BaseNode & { variant: "leaf"; value: string };

export type Link = BaseNode & { variant: "link"; to: string };

export type Branch = BaseNode & {
  variant: "branch";
  children: ((ctx: string) => (Variant | Group | Sep)[]) | (Variant | Group | Sep)[];
};

export type Factory = () => Branch;

export type Variant = Leaf | Link | Branch;

export type Group = { kind: "group"; name: string; items: (Variant | Sep)[] };

export type Sep = { kind: "sep" };
