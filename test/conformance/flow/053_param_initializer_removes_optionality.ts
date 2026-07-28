// A parameter with an initializer is optional at the CALL SITE — passing
// `undefined` is how you select the default — but inside the BODY it never
// observes `undefined`, precisely because that is the case the default fills
// in. tsc calls the second half `removeOptionalityFromDeclaredType`.
//
// ztsc had only the first half: it widened the signature copy with
// `| undefined` and pinned the body symbol to the declared type unchanged.
// That was invisible while the annotation was undefined-free, and wrong the
// moment the annotation itself spelled `undefined` — which an alias routinely
// does.

type Data = { items?: readonly string[] };

// The annotation is `readonly string[] | undefined`; in the body it is not.
export function viaAlias(xs: Data["items"] = []) {
  for (const x of xs) {
    return x;
  }
  return "";
}

// Written out, same thing.
export function spelled(xs: readonly string[] | undefined = []) {
  return xs.length;
}

// The call site keeps the optionality both ways.
export const noArgs = spelled();
export const explicitUndefined = spelled(undefined);

// A destructured parameter's bindings come from the same pinned type.
export function destructured(
  { a }: { a: string } | undefined = { a: "x" },
): string {
  return a;
}

// Without an initializer the `undefined` stays, and the body must guard.
export function noInitializer(xs: readonly string[] | undefined) {
  return xs.length;
}

// tsc's carve-out: an initializer that can ITSELF be undefined leaves the
// parameter genuinely undefined-able inside.
declare const maybe: readonly string[] | undefined;
export function initializerMayBeUndefined(
  xs: readonly string[] | undefined = maybe,
) {
  return xs.length;
}

// An explicit `?` parameter cannot carry an initializer, so the only
// interaction to check is that a plain optional is untouched.
export function optionalParam(xs?: readonly string[]) {
  return xs.length;
}

// `null` is not `undefined`: only `undefined` is removed.
export function keepsNull(xs: readonly string[] | null = []) {
  return xs.length;
}
