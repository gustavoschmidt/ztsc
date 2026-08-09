// tsc's `getTypeForVariableLikeDeclaration` order for a PARAMETER is: the
// type annotation, then the CONTEXTUAL parameter type, and only then the
// initializer. A default therefore does not replace the contextual type it
// is a default FOR — it only removes `undefined` from it
// (`removeOptionalityFromDeclaredType`, which fires for a parameter with an
// initializer).
//
// ztsc read the initializer first, so `build(params = {})` written against
// `build: (params?: Record<string, any>) => string` typed `params` as `{}`
// and every `params[name]` was a false TS7053.

type Route = {
  build: (params?: Record<string, any>) => string;
  plain: (params: Record<string, any>) => string;
  n: (x?: number) => number;
};

export const route: Route = {
  build(params = {}) {
    return String(params["k"]);
  },
  plain(params) {
    return String(params["k"]);
  },
  n(x = 1) {
    // `undefined` is gone, so this is `number`, not `number | undefined`.
    return x + 1;
  },
};

// With NO contextual signature the initializer still supplies the type.
export function standalone(params = { a: 1 }) {
  return params.a;
}

// An explicit annotation still wins over both.
export const annotated: Route = {
  build(params: Record<string, string> = {}) {
    return params["z"];
  },
  plain(params) {
    return String(params["k"]);
  },
  n(x = 1) {
    return x + 1;
  },
};

// NEGATIVES — the contextual type is `Record<string, any>`, not `{}`, and
// not the initializer's shape.
export const bad: Route = {
  build(params = {}) {
    const wrong: { specific: number } = params;
    return String(wrong.specific);
  },
  plain(params) {
    return String(params["k"]);
  },
  n(x = 1) {
    const s: string = x;
    return s.length;
  },
};

export function badStandalone(params = { a: 1 }) {
  return params.b;
}
