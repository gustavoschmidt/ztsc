import { Box, wrap } from "./box";
const b: Box<number> = wrap(1);
const n: number = b.value;
const s: string = b.value;
