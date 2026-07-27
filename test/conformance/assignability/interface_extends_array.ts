// `interface X extends Array<T>` must inherit the array's members. ztsc
// models an array with a dedicated array kind rather than the lib `Array<T>`
// interface's object, so the heritage merge (object-to-object) dropped the
// whole base — `RegExpMatchArray.length` was TS2339.
interface Array<T> {
  slice(start?: number): T[];
  join(sep?: string): string;
}

interface Matches extends Array<string> {
  index?: number;
}

declare const m: Matches;
const a: number = m.length;
const b: string[] = m.slice(1);
const c: string = m.join(',');
const d: number | undefined = m.index;
const e: string = m.length; // TS2322
const f = m.absentMember; // TS2339

// The derived interface's own members are still assignable structurally.
declare function takesMatches(v: Matches): void;
takesMatches(m);
