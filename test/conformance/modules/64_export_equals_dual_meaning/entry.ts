import Test from "stest";
import { Request, Opts, version } from "sagent";

// The class inherited its base through the VALUE meaning of `Request`.
declare const t: Test;
const a: string = t.expect(200).accept("json").method;

// Both meanings of the same imported name, in one file.
declare const r: Request; // type meaning: the namespace's interface
const b: string = r.accept("x").method;
const c: Request = new Request("GET", "/"); // value meaning: typeof SARequest

// A name with only a type meaning, and one with only a value meaning.
const d: Opts = { deep: true };
const e: string = version;

// Negative controls: the declared types are kept on both meanings.
const bad1: number = t.method;
const bad2: number = new Request("GET", "/").method;
const bad3 = version(1);

export { a, b, c, d, e, bad1, bad2, bad3 };
