type MyReadonly<T> = { readonly [K in keyof T]: T[K] };
type MyPick<T, K extends keyof T> = { [P in K]: T[P] };

interface Foo { x: number; y: string; z: boolean; }

declare const ro: MyReadonly<Foo>;
const rx: number = ro.x;
ro.x = 5; // TS2540 (read-only)

declare const pick: MyPick<Foo, "x" | "y">;
const pkx: number = pick.x;
const pky: string = pick.y;
const pkz = pick.z; // TS2339 (z not picked)
