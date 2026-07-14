interface CallObj { (x: number): number; }
declare const co: CallObj;
const fn: (x: number) => number = co;
declare const plain: (x: number) => number;
const co2: CallObj = plain;
const badfn: (x: string) => string = co;
