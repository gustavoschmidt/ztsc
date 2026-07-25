// A function with no return annotation whose body is a `switch` covering every
// member of a literal-union discriminant (no `default`, every clause ends
// terminally) has an unreachable fall-through end. tsc infers its return type
// WITHOUT a phantom `| undefined`. The exhaustiveness check must synthesize the
// discriminant and case-label types on demand — the return-type inference probe
// types only `return` expressions, so those nodes are otherwise uncached.
type Fmt = 'snake' | 'camel' | 'kebab';

function apply(k: Fmt, s: string) {
  switch (k) {
    case 'snake':
      return s.replace(/ /g, '_');
    case 'camel':
      return s.toLowerCase();
    case 'kebab':
      return 1;
  }
}

// Return type is `string | number` (no undefined) — assignable to the target.
const r: string | number = apply('snake', 'x');

// A NON-exhaustive switch (a missing member) still falls through, so its
// inferred return keeps `| undefined` and the assignment errors.
function partial(k: Fmt, s: string) {
  switch (k) {
    case 'snake':
      return s;
    case 'camel':
      return s;
  }
}
const bad: string = partial('kebab', 'x');
