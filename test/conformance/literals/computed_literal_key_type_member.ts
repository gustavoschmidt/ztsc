// A computed property name whose expression is a literal is late-bound to
// exactly that literal's own name, so `['data-state']: string` in a type
// literal is indistinguishable from `'data-state': string`. Radix-style prop
// bags (bluesky's `RadixPassThroughTriggerProps`) are written this way.
type Trigger = {
    id: string;
    ["data-disabled"]: boolean;
    ["data-state"]: string;
    ["aria-controls"]?: string;
    [0]: number;
};

interface ITrigger {
    ["data-state"]: string;
    readonly ["data-open"]?: boolean;
    ["run"](n: number): string;
}

declare const t: Trigger;
const a: boolean = t["data-disabled"];
const b: string = t["data-state"];
const c: string | undefined = t["aria-controls"];
const d: number = t[0];

declare const i: ITrigger;
const e: string = i["data-state"];
const f: string = i.run(1);

// The key really is that name, so the wrong type is still an error.
const bad: number = t["data-state"];

// …and a name that was never declared is still missing.
const missing = t["data-nope"];

export { a, b, c, d, e, f, bad, missing };
