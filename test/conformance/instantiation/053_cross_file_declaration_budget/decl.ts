// A declaration whose materialization costs far more than one source
// element's instantiation budget (`max_instantiation_count`, 250 k node
// visits) but far less than a declaration window's
// (`max_decl_instantiation_count`).
//
// `Wide` is 1,000 string literals and `Table` maps every one of them to a
// 1,000-member union built by a distributive conditional, so materializing
// `Table` walks on the order of a million nodes — and it is materialized
// exactly once, cross-file, on whatever statement in `entry.ts` demands it
// first. Charged against that STATEMENT's budget it comes back truncated to
// `error_type`, a suppressing type, and every read off it goes quiet: the
// case reports nothing at all where tsgo reports two assignments. Charged
// against the declaration window's own budget it completes, is memoized
// complete under the symbol, and every reader sees the same finished type.
type Digit = '0' | '1' | '2' | '3' | '4' | '5' | '6' | '7' | '8' | '9';
type Wide = `${Digit}${Digit}${Digit}`;
type Cross<K, U> = U extends string ? `${K & string}.${U}` : never;

export type Table = { [K in Wide]: Cross<K, Wide> };

declare const table: Table;
export const rows = table;
