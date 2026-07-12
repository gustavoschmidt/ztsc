interface TreeA { value: number; next: TreeA | null; }
interface TreeB { value: number; next: TreeB | null; }
declare const a: TreeA;
const b: TreeB = a;
interface TreeC { value: string; next: TreeC | null; }
declare const c2: TreeA;
const d: TreeC = c2;
