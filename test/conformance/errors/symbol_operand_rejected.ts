// tsc's `checkForDisallowedESSymbolOperand`: "symbols are not allowed at all
// in arithmetic expressions". TS2469 fires for unary `+`/`-`/`~`, for `+`
// and `+=` once a result type has been determined, and for the four
// relational operators — in which case NONE of the comparison checks run.
//
// The test is `maybeTypeOfKindConsideringBaseConstraint`: ANY constituent
// carrying `symbol`, or a type parameter whose constraint does. The message
// names the operator AS WRITTEN, so `+=` is not spelled `+`.

export {};

declare let s: symbol;
declare let sn: symbol | number;
declare let n: number;
declare const us: unique symbol;

+s;
-s;
~s;
+sn;
+(s as symbol | number);

s + "";
"" + s;
sn + 1;
us + "";

s < s;
s > n;
n <= s;
s >= s;

let acc = "";
acc += s;

export function constrained<S extends symbol>(k: S) {
  +k;
  k + "";
  k < k;
}

export function halfConstrained<S extends symbol | string>(k: S) {
  +k;
}

// Negative controls: `!` is fine on anything, and a non-symbol operand is
// left to the ordinary operator rules.
!s;
typeof s;
+n;
n + 1;
n < 1;
export function unconstrained<T>(t: T) {
  return t < t;
}
