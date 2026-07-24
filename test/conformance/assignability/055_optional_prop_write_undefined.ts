// With exactOptionalPropertyTypes off, an optional property's type folds in
// `| undefined`, so `undefined` is a legal WRITE target for it — exactly as the
// read type already includes `undefined`. The write-target type must not be
// narrower than the read type.
type P = { prev?: string | null; count?: number };

function direct(x: P) {
  x.prev = undefined; // clean
  x.count = undefined; // clean
}

function viaSpread(src: P) {
  const api = { ...src };
  api.prev = undefined; // clean: spread preserves optionality
}

// NEG CONTROL: a REQUIRED property does not accept `undefined`.
type Q = { name: string };
function bad(q: Q) {
  q.name = undefined; // TS2322: 'undefined' not assignable to 'string'
}
