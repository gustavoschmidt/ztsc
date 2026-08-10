// Two forms of TS 4.6 dependent destructured variables that the equality and
// `switch` narrowers do not reach: a BOOLEAN discriminant — the guard is the
// binding itself, there is no comparand to write — and a `const` declarator
// whose parent type comes from its INITIALIZER rather than an annotation.
type Maybe =
  | { detached: false; quote: string; quoteUri: undefined }
  | { detached: true; quote: undefined; quoteUri: string };

function viaTruthiness({ detached, quote, quoteUri }: Maybe): string {
  if (detached) {
    return quoteUri;
  }
  return quote;
}

function viaNegation({ detached, quote, quoteUri }: Maybe): string {
  if (!detached) {
    return quote;
  }
  return quoteUri;
}

function viaTernary({ detached, quote, quoteUri }: Maybe): string {
  return detached ? quoteUri : quote;
}

function viaAnd({ detached, quoteUri }: Maybe): string {
  return detached && quoteUri !== "" ? "y" : "n";
}

// The renamed form binds the same property.
function viaRename({ detached: d, quote: q }: Maybe): string {
  if (d) {
    return "";
  }
  return q;
}

// A `const` destructuring with no annotation: the parent union is the type of
// the initializer, exactly as the bindings' own declared types are.
type Picked =
  | { canceled: true; assets: undefined }
  | { canceled: false; assets: { n: number } };
declare function pick(): Picked;

function viaInitializer(): number {
  const { assets, canceled } = pick();
  if (canceled) {
    return 0;
  }
  return assets.n;
}

// The same, discriminated by equality rather than truthiness.
type Tagged = { kind: "a"; v: string } | { kind: "b"; v: undefined };
declare function tagged(): Tagged;

function viaInitializerEquality(): string {
  const { kind, v } = tagged();
  if (kind === "b") {
    return "";
  }
  return v;
}

export {
  viaTruthiness,
  viaNegation,
  viaTernary,
  viaAnd,
  viaRename,
  viaInitializer,
  viaInitializerEquality,
};
