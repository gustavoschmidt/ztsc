import { rows } from './decl.js';

// Two reads of the SAME cross-file declaration. Both must see the finished
// member type: a truncation published under the symbol would silence both,
// and a truncation re-derived per reader would silence whichever one paid
// for it.
export const a: number = rows['000'];
export const b: number = rows['999'];
