// Guard rails on 110. Publishing a loop label's partial fixpoint for every
// back-edge walk makes the checker narrow MORE, so each way a loop must
// still re-widen is pinned here.

type Classified =
  | { ok: true; kind: "video" | "image" | "gif"; mime: string }
  | { ok: false; kind: undefined; mime: undefined };

declare function classify(n: number): Classified;
declare function next(): string | undefined;

// Read BEFORE the guard: the loop head is reached both from the entry edge
// and from the back edge, and neither carries the `ok` narrowing.
function beforeGuard(ns: number[]) {
  let dominant: "video" | "image" | "gif" | undefined;
  for (const n of ns) {
    const { ok, kind, mime } = classify(n);
    const early: string = mime;
    if (!ok) {
      continue;
    }
    dominant = dominant || kind;
    void early;
  }
  return dominant;
}

// A binding that is assigned inside the loop is not const-like, so the
// sibling relationship is broken and no guard relates `mime` to `ok`.
function assignedBinding(ns: number[]) {
  let dominant: "video" | "image" | "gif" | undefined;
  for (const n of ns) {
    let { ok, kind, mime } = classify(n);
    if (!ok) {
      continue;
    }
    mime = undefined;
    dominant = dominant || kind;
    const m: string = mime;
    void m;
  }
  return dominant;
}

// A guard that does not cover every constituent leaves the others in.
function partialGuard(ns: number[]) {
  let dominant: "video" | "image" | "gif" | undefined;
  for (const n of ns) {
    const { ok, kind } = classify(n);
    if (!ok) {
      continue;
    }
    dominant = dominant || kind;
    const only: "video" = kind;
    void only;
  }
  return dominant;
}

// A narrowing established before the loop must be re-widened at the head by
// an assignment further down the body, on the back edge.
function reWidenAcrossBackEdge(ns: number[]) {
  let s: string | undefined = "a";
  let n = 0;
  for (const _x of ns) {
    n += s.length;
    s = next();
  }
  return n;
}

export { beforeGuard, assignedBinding, partialGuard, reWidenAcrossBackEdge };
