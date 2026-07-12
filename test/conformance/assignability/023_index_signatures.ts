interface Dict { [key: string]: number; }
declare const good: { a: number; b: number };
const d1: Dict = good;
declare const bad: { a: number; b: string };
const d2: Dict = bad;
declare const dict: Dict;
const n: number = dict["anything"];
