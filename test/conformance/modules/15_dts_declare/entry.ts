import { parse, VERSION, Config } from "./api";
const c: Config = { strict: true, depth: 3 };
const n: number = parse("x", c);
const bad: boolean = VERSION;
