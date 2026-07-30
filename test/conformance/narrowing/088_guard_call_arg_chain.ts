// A type-predicate call whose ARGUMENT is an optional chain asserts, on its
// true branch, that the chain did not short-circuit — so the chain's receivers
// are non-nullish there. tsc's `narrowTypeByTypePredicate` optional-chain arm;
// the same rule truthiness/`typeof`/`instanceof` narrowing already apply.
type Payload = { message?: unknown; detail?: unknown };
declare const data: Payload | undefined;

export function a(): number {
  if (Array.isArray(data?.detail) && data.detail.length) {
    return data.detail.length;
  }
  return 0;
}

// user-defined guard, deeper chain: every receiver on the spine is asserted
type Node2 = { child?: { value?: string | number } };
declare function isStr(x: unknown): x is string;

export function b(n: Node2 | undefined): number {
  if (isStr(n?.child?.value)) {
    return n.child.value.length;
  }
  return 0;
}

// element-access link on the spine
export function c(xs: { v?: string }[] | undefined): number {
  if (isStr(xs?.[0].v)) {
    return xs[0].v.length;
  }
  return 0;
}

// the guarded parameter is not the first one
declare function isNum(tag: string, x: unknown): x is number;

export function d(n: Node2 | undefined): number {
  if (isNum("t", n?.child?.value)) {
    return n.child.value;
  }
  return 0;
}
