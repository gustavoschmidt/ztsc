interface RO { readonly id: number; }
declare const mut: { id: number };
const a: RO = mut;
declare const ro: RO;
const b: { id: number } = ro;
