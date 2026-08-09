// tsc's optional-chain containment applied to a SWITCH discriminant: an
// optional read (`switch (x?.k)`) short-circuits to `undefined` when the
// receiver is nullish, so a `case` label that is not itself nullish forces the
// receiver non-nullish on that clause. ztsc applied the rule to
// `if (x?.k === lit)` but not to the switch form, and the discriminant filter
// alone keeps `undefined` (a constituent with no `k` is conservatively kept) —
// so every `case` body read the receiver as possibly undefined.

type Payload =
  | { reason: "like"; subject: string }
  | { reason: "reply"; uri: string }
  | { reason: "chat"; convoId: string }
  | undefined;

export function f(payload: Payload): string | null {
  switch (payload?.reason) {
    case "like":
      return payload.subject;
    case "reply":
      return payload.uri;
    case "chat":
      return payload.convoId;
    default:
      return null;
  }
}

// `default:` is exactly where a short-circuited chain lands, so the receiver
// stays nullable there.
export function g(payload: Payload): string {
  switch (payload?.reason) {
    case "like":
      return payload.subject;
    default:
      return payload?.reason ?? "none";
  }
}

// A `case undefined:` label does not force the receiver non-nullish.
type Maybe = { k: "a"; v: string } | undefined;
export function h(m: Maybe): string {
  switch (m?.k) {
    case "a":
      return m.v;
    case undefined:
      return "none";
  }
}

// The `if` form, which already worked.
export function i(payload: Payload): string | null {
  if (payload?.reason === "like") return payload.subject;
  return null;
}

// A plain (non-optional) discriminant switch is unchanged.
type Sure = { reason: "like"; subject: string } | { reason: "reply"; uri: string };
export function j(p: Sure): string {
  switch (p.reason) {
    case "like":
      return p.subject;
    case "reply":
      return p.uri;
  }
}
