// An arrow whose contextual type is a callable INTERFACE — a call signature
// plus ordinary properties — must take its parameter types from that signature.
// tsc's `getContextualSignature` reads the type's call signatures and uses the
// sole one; ztsc only looked through `.function` (and `.function` inside a
// union), so the arrow got no contextual parameter types and reported TS7006.
//
// Two shapes reach this: React's `const Base: FunctionComponent<Props> =
// (props) => …` (a call signature plus `displayName?`), and rxjs's
// `OperatorFunction<T, R> extends UnaryFunction<Observable<T>, Observable<R>>`
// returned from an operator factory.
interface FC<P> {
  (props: P): string | null;
  displayName?: string | undefined;
}
type Props = { a?: string; n: number };

const Base: FC<Props> = (props) => {
  const a: string | undefined = props.a;
  const n: number = props.n;
  const bad: string = props.n;
  return null;
};

interface Unary<T, R> {
  (source: T): R;
}
interface Op<T, R> extends Unary<T[], R[]> {}
declare function make<T>(n: number): Op<T, T>;
declare function opFrom<T, R>(f: (source: T[]) => R[]): Op<T, R>;
function skip<T>(count: number): Op<T, T> {
  return opFrom((source) => {
    const first: T = source[0];
    const oops: number = source;
    return source;
  });
}

// A callable interface reached through a UNION contextual type keeps working.
type MaybeFC = FC<Props> | undefined;
const maybe: MaybeFC = (props) => {
  const n: number = props.n;
  return null;
};

export { Base, skip, make, maybe };
