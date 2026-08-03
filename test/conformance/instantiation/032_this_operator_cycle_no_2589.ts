// A fluent schema hierarchy whose members are written in terms of the
// polymorphic `this` — zod v4's `$ZodType`. `Out<T>` reads a schema's output
// through an indexed access, and the base declares members typed with
// `Out<this>`, so substituting a receiver for `this` reaches `Out<receiver>`,
// whose reduction looks the member up again and reaches `Out<this>` once more.
// The circle closes on the identical (type, receiver) pair, and — through the
// constraint `Base<any, Out<this>>` — also as a strictly growing
// `Base<any, Base<any, …>>` chain that never repeats a type at all.
//
// tsc resolves an indexed access on a type variable lazily and never enters
// either circle. ztsc reduces eagerly, so both have to be cut explicitly; when
// they were not, the instantiation depth cap truncated the schema to the error
// type and reported TS2589 at the member access that demanded it — taking
// every property of the resulting object type with it.

interface Internals<out O = unknown, out I = unknown> {
  output: O;
  input: I;
}

type Out<T> = T extends { _zod: { output: any } } ? T['_zod']['output'] : unknown;
type In<T> = T extends { _zod: { input: any } } ? T['_zod']['input'] : unknown;

interface Standard<I, O> {
  validate: (value: I) => O;
}

interface Base<O = unknown, I = unknown, N extends Internals<O, I> = Internals<O, I>> {
  _zod: N;
  '~standard': Standard<In<this>, Out<this>>;
  check(...checks: ((value: Out<this>) => void)[]): this;
  optional(): Opt<this>;
  array(): Arr<this>;
  accept(target: Base<any, Out<this>>): this;
  pipe<T extends Base<any, Out<this>>>(target: T | Base<any, Out<this>>): Pipe<this, T>;
  describe(text: string): this;
}

interface PipeInternals<A extends { _zod: { output: any; input: any } }, B extends { _zod: { output: any; input: any } }>
  extends Internals<Out<B>, In<A>> {
  first: A;
  second: B;
}
interface Pipe<A extends { _zod: { output: any; input: any } }, B extends { _zod: { output: any; input: any } }>
  extends Base<Out<B>, In<A>, PipeInternals<A, B>> {}

interface OptInternals<T extends { _zod: { output: any; input: any } }>
  extends Internals<Out<T> | undefined, In<T> | undefined> {
  inner: T;
}
interface Opt<T extends { _zod: { output: any; input: any } }>
  extends Base<Out<T> | undefined, In<T> | undefined, OptInternals<T>> {}

interface ArrInternals<T extends { _zod: { output: any; input: any } }> extends Internals<Out<T>[], In<T>[]> {
  element: T;
}
interface Arr<T extends { _zod: { output: any; input: any } }>
  extends Base<Out<T>[], In<T>[], ArrInternals<T>> {}

interface Schema<O, I> extends Base<O, I, Internals<O, I>> {}

type Point = { x: number; y: number };

declare const point: Schema<Point, string>;
declare const anyPoint: Base<any, Point>;

// Each link substitutes a fresh receiver for `this` and reduces `Out<this>`
// against it; the accept/check arguments drag the constraint's own `Out<this>`
// into the same walk.
const chained = point.accept(anyPoint).describe('a point').optional().array();

const out: (Point | undefined)[] = chained._zod.output;
const inp: (string | undefined)[] = chained._zod.input;
const inner: Point | undefined = chained._zod.element._zod.output;
const std = chained['~standard'].validate([undefined, 'x']);

// The generic form of the same constraint. `T`'s bound mentions `Out<this>`,
// so materializing the signature at the call site re-enters the walk with the
// bound's own `Base<any, Out<this>>` as the receiver — the growing chain.
declare const acceptsPoint: Base<{ ok: boolean }, Point>;
const piped = point.pipe(acceptsPoint).optional().array().optional().describe('piped');

export { chained, out, inp, inner, std, piped };
