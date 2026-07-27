// @ts-nocheck
// Every semantic diagnostic in the file is suppressed: the assignment below
// and the duplicate block-scoped declaration (a bind diagnostic) both vanish.
const x: string = 1;
let dup: number = 1;
let dup: number = 2;
