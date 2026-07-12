interface Rec { id: number; label: string; }
declare const v1: Rec["id"];
const n: number = v1;
declare const v2: Rec["label"];
const s: string = v2;
