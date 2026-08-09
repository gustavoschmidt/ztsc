// A specifier that already names a TypeScript extension is NOT taken
// literally: tsc strips it and re-probes the whole family, so "./sub.ts"
// finds sub.d.ts. date-fns v4 ships its barrel entirely this way.
import { sub } from "./barrel.ts";
import { plain } from "./plain.ts";

const a: number = sub(1);
const b: string = plain;

export { a, b };
