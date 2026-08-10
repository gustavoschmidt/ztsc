// A tuple is an ordinary object type in tsc -- its elements ARE the properties
// `"0"`, `"1"`, ... -- so `typeRelatedToDiscriminatedType` applies to it
// unchanged. The shape that decides is an "overloaded" argument list spelled
// as a union of tuples, which is how react-navigation types `navigate`:
// a call whose first argument is a route-name UNION builds the spread tuple
// `["HomeTab" | "SearchTab"]` (tsc's `getSpreadArgumentType`), which fits no
// single constituent, and is accepted by splitting position 0 into cases.

type Tab = 'Home' | 'Search';
type Args =
  | ['HomeTab', undefined?, { merge?: boolean }?]
  | ['SearchTab', undefined?, { merge?: boolean }?]
  | ['Other', { q: string }, { merge?: boolean }?];

declare function nav(...args: Args): void;

declare const pair: ['HomeTab' | 'SearchTab', undefined];
declare const wrong: ['HomeTab' | 'Nope'];
declare const payload: ['HomeTab' | 'Other'];

export function go(tab: Tab) {
  nav(`${tab}Tab`);
  nav('HomeTab');
  const a: Args = pair;

  // A case no constituent covers still reports.
  const b: Args = wrong; // TS2322

  // Splitting the tag is not enough on its own: the `Other` case needs a
  // second element the source does not have.
  const c: Args = payload; // TS2322
}
