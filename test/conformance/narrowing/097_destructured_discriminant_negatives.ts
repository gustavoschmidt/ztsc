// The cases where a destructured discriminant must NOT narrow its siblings.
type Req =
  | { kind: "a"; data: { x: string } }
  | { kind: "b"; data: { y: number } };

// Wrong branch: `kind === "a"` leaves `data` at `{ x: string }`.
function wrongBranch({ kind, data }: Req): number {
  if (kind === "a") {
    return data.y;
  }
  return 0;
}

// A reassigned discriminant is not a discriminant at all.
function reassigned({ kind, data }: Req): string {
  kind = "a";
  if (kind === "a") {
    return data.x;
  }
  return "";
}

// A defaulted binding has an initializer, so it is not a dependent binding.
function defaulted({ kind = "a", data }: Req): string {
  if (kind === "a") {
    return data.x;
  }
  return "";
}

// A single-element pattern has no sibling to narrow.
function unguarded({ data }: Req): string {
  return data.x;
}

export { wrongBranch, reassigned, defaulted, unguarded };
