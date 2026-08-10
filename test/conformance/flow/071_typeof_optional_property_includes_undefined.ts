// A type query on an OPTIONAL property carries `| undefined` (tsc bakes it
// into the symbol's type with `addOptionality`, and a type query is just
// `getTypeOfSymbol`). A `let` whose declared type already includes
// `undefined` is exempt from definite-assignment analysis, so the read below
// must NOT be TS2454.
interface Post {
  embed?: { a: string } | { b: string };
}
declare const post: Post;

declare function pick(c: boolean): boolean;

function merge(c: boolean) {
  let embed: typeof post.embed;
  if (pick(c)) {
    embed = post.embed;
  }
  return embed || post.embed; // no TS2454: declared type includes undefined
}

// `undefined` really is in the query's type.
type E = typeof post.embed;
const e: E = undefined;

// A required property's query does not gain one, so the same shape still
// reports TS2454.
interface Req {
  v: string;
}
declare const req: Req;
function merge2(c: boolean) {
  let v: typeof req.v;
  if (pick(c)) {
    v = req.v;
  }
  return v; // TS2454
}

declare const m1: (c: boolean) => { a: string } | { b: string } | undefined;
const m2 = merge;
const m3: typeof m1 = m2;
