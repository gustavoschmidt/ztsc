type Pair = [first: number, second: string];
declare const p: Pair;
const a: number = p[0];
const b: string = p[1];
type WithRest = [head: string, ...tail: number[]];
type WithOpt = [x: number, y?: string];
declare const w: WithOpt;
const bad: string = p[0];
