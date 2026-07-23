// A merged/curried callable can carry its call (or construct) signatures on an
// OBJECT member of an intersection — an interface with call signatures — rather
// than as a `.function`/`.overloads`. RTK's
//   `createAsyncThunk: CreateAsyncThunkFunction<C> & { withTypes(): … }`
// is exactly this shape: the callable arm is an object bearing call sigs. The
// intersection-member scan in the call/new path must accept that member and
// resolve against its signatures instead of falling through to TS2349/TS2351.
interface CallableIface {
  <T>(x: T): T[];
}
type Curried = CallableIface & { withTypes: () => Curried };

declare const f: Curried;

const r = f<number>(3); // resolves via the object call signature -> number[]
const first: number = r[0];
const nested: Curried = f.withTypes();
const r2 = nested('hi'); // string[]
const s: string = r2[0];

// `new` form: construct signatures presented on an object intersection member.
interface CtorIface {
  new (n: number): { v: number };
}
type CurriedCtor = CtorIface & { extra: string };

declare const C: CurriedCtor;

const inst = new C(5);
const v: number = inst.v;

// Negative control — an intersection whose members are all NON-callable stays
// TS2349 (the scan must not make every intersection callable).
type Plain = { a: number } & { b: string };
declare const p: Plain;
p(); // TS2349
