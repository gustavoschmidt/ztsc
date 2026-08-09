// `const {[key]: v, ...rest} = o` — an object binding pattern with a COMPUTED
// key. The key is an ordinary expression read from the enclosing scope, the
// target binds `o[typeof key]`, and a non-literal key omits nothing from the
// rest type (bluesky's translation-state reducer).
declare const counts: Record<string, number>;
declare const key: string;

const { [key]: hit, ...rest } = counts;
const n: number = hit;
const r: Record<string, number> = rest;

type Point = { x: number; y: string };
declare const p: Point;
const { ["x"]: xx, ...pr } = p;
const xn: number = xx;
const ys: string = pr.y;

// A default on the computed element still applies.
const { [key]: withDefault = 7 } = counts;
const wd: number = withDefault;

// Wrong target type is still an error.
const bad: string = hit;

function reducer(prev: Record<string, number>, k: string): Record<string, number> {
    const { [k]: _drop, ...kept } = prev;
    return kept;
}

export { n, r, xn, ys, wd, bad, reducer };
