interface Opts { name: string; flag?: boolean; }
declare const a: { name: string };
const o1: Opts = a;
declare const b: { name: string; flag: boolean };
const o2: Opts = b;
declare const c: { name?: string; flag?: boolean };
const o3: Opts = c;
