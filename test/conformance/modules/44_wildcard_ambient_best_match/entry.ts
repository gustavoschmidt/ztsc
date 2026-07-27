/// <reference path="./shims.d.ts" />
import raw from "./file.txt?raw";
import Worker from "./worker.ts?worker&inline";
import styles from "./a.module.css";
import { tag } from "prefix-deep-thing";

const s: string = raw;
const w: number = new Worker();
const c: string = styles.foo;
const t: boolean = tag; // `prefix-deep-*`, not `prefix-*`

// Wrong types, proving each really resolved to its declared shape.
const s2: number = raw; // TS2322
const t2: number = tag; // TS2322 — number here would mean `prefix-*` had won

export { s, w, c, t, s2, t2 };
