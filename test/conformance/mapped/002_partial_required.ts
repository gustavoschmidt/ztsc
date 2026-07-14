// The classic library mapped types, reimplemented locally.
type MyPartial<T> = { [K in keyof T]?: T[K] };
type MyRequired<T> = { [K in keyof T]-?: T[K] };

interface Point { x: number; y: number; }

declare const p: MyPartial<Point>;
const px: number | undefined = p.x;   // optional -> includes undefined
const bad: number = p.x;              // TS2322

interface Opt { a?: number; b?: string; }
declare const r: MyRequired<Opt>;
const ra: number = r.a;               // -? strips optional AND undefined
const rb: string = r.b;
const rbad: number = r.b;             // TS2322 (b is string)
