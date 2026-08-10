// Guard rails on 107: the conditions tsc puts on `getNarrowedTypeOfSymbol`.
type Maybe =
  | { detached: false; quote: string; quoteUri: undefined }
  | { detached: true; quote: undefined; quoteUri: string };

// The wrong branch narrows to the wrong constituent.
function wrongBranch({ detached, quote }: Maybe): string {
  if (detached) {
    return quote;
  }
  return "";
}

type Picked =
  | { canceled: true; assets: undefined }
  | { canceled: false; assets: { n: number } };
declare function pick(): Picked;

// `let` is not const-like: the declaration could be reassigned, so tsc does
// not relate the two bindings at all.
function notConst(): number {
  let { assets, canceled } = pick();
  if (canceled) {
    return 0;
  }
  return assets.n;
}

// A binding that IS assigned somewhere is not const-like either, even as a
// parameter — the relationship to its siblings could have been broken.
function reassignedBinding({ detached, quoteUri }: Maybe): string {
  if (detached) {
    const uri: string = quoteUri;
    return uri;
  }
  quoteUri = "z";
  return quoteUri;
}

// A binding with a default does not participate (tsc requires the binding
// element to have no initializer of its own).
type MaybeOpt =
  | { detached?: false; quote: string }
  | { detached: true; quote: undefined };

function withDefault({ detached = false, quote }: MaybeOpt): string {
  if (!detached) {
    return quote;
  }
  return "";
}

// A single-element pattern has no sibling to narrow by.
function loneBinding({ quote }: Maybe): string {
  return quote;
}

export { wrongBranch, notConst, reassignedBinding, withDefault, loneBinding };
