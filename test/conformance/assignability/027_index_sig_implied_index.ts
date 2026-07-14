// Object/type literals carry an *implied* string index; interfaces and class
// instances do not. All the accepted forms conform member-by-member.
type SIdx = { [k: string]: number };
const fresh: SIdx = { a: 1, b: 2 };
const widened = { a: 1, b: 2 };
const fromVar: SIdx = widened;
type TL = { a: number; b: number };
declare const tl: TL;
const fromLiteralAlias: SIdx = tl;
const empty: SIdx = {};
const badMember: SIdx = { a: 1, b: "x" };
interface Empty {}
declare const e: Empty;
const fromEmptyIface: SIdx = e;
