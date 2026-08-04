// A guard on one binding of a destructured discriminated union narrows the
// SIBLING bindings (TS 4.6 dependent destructured parameters).
type Req =
  | { kind: "a"; data: { x: string }; extra: number }
  | { kind: "b"; data: { y: number }; extra: number };

function viaSwitch({ kind, data }: Req): string {
  switch (kind) {
    case "a":
      return data.x;
    case "b":
      return "" + data.y;
  }
}

function viaIf({ kind, data }: Req): string {
  if (kind === "a") {
    return data.x;
  }
  return "" + data.y;
}

function viaEarlyReturn({ kind, data }: Req): string {
  if (kind !== "a") {
    return "" + data.y;
  }
  return data.x;
}

// The renamed form binds the same property.
function viaRename({ kind: k, data: d }: Req): string {
  if (k === "b") {
    return "" + d.y;
  }
  return d.x;
}

// A narrowed sibling is still narrowable in its own right.
type Inner = { tag: "p"; v: string } | { tag: "q"; v: number };
function nested({ kind, data }: { kind: "a"; data: Inner } | { kind: "b"; data: null }): string {
  if (kind === "a") {
    if (data.tag === "p") {
      return data.v;
    }
    return "" + data.v;
  }
  return "";
}

export { viaSwitch, viaIf, viaEarlyReturn, viaRename, nested };
