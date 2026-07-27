// A generic interface whose type-parameter list and `extends` clause live in
// one declaration block while another block reopens it WITHOUT a parameter
// list — the shape real `@types/node` uses for `Buffer`
// (`interface Buffer<TArrayBuffer extends ArrayBufferLike = ArrayBufferLike>
// extends Uint8Array<TArrayBuffer>` in one file, a bare `interface Buffer { … }`
// reopen in another). The bare block must not erase the parameters, and a
// `this`-returning member declared on it must still relate to the base's own
// `this`-returning member.
import "./base";
import "./reopen";

declare const box: Box;

const asBase: Holder<string> = box;
const asSelf: Box<string> = box;
const payload: string = box.payload;
const label: string = box.label();
const chained: Box<string> = box.self();
const narrowed: Box<string> = box.narrow();

declare const numbox: Box<number>;
const numBase: Holder<number> = numbox;
const numPayload: number = numbox.payload;

// The relation is not blanket-accepted: the default argument is `string`.
const wrongArg: Holder<number> = box;

// The same shape within ONE file, with the bare block FIRST.
interface Pair {
  first(): this;
}
interface Pair<T = string> extends Holder<T> {
  second(): Pair<T>;
}
declare const pair: Pair;
const pairBase: Holder<string> = pair;
const pairPayload: string = pair.payload;
const pairFirst: Pair<string> = pair.first();
const pairWrong: Holder<number> = pair;
