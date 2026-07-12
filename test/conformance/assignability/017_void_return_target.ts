type Task = () => void;
declare const f: () => number;
const t: Task = f;
declare const g: () => void;
const n: () => number = g;
