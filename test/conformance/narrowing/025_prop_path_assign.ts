interface Holder { value: string | null; }
declare const h: Holder;
h.value = "x";
const s: string = h.value;
