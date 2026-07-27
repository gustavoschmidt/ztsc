export {};

enum EVENT {
  KEYDOWN = "keydown",
  PASTE = "paste",
  LINK = "excalidraw-link",
}

// A string-enum member is a subtype of the literal it is initialized with.
const a: "keydown" = EVENT.KEYDOWN;
const b: "paste" = EVENT.PASTE;
const c: "keydown" | "paste" = EVENT.KEYDOWN;
const d: string = EVENT.KEYDOWN;

// The overload-selection shape this unblocks: `K` infers to the member type,
// which satisfies `K extends keyof M`.
interface M {
  keydown: { k: 1 };
  paste: { p: 1 };
}
declare function on<K extends keyof M>(type: K, h: (e: M[K]) => void): void;
declare const h: (e: { k: 1 }) => void;
on(EVENT.KEYDOWN, h);
on("keydown", h);

// NEGATIVE: a literal that is not any member's value.
const e: "click" = EVENT.KEYDOWN;
const f: "keydown" = EVENT.LINK;

// NEGATIVE: nothing widens INTO a nominal string enum.
const g: EVENT = "keydown";
declare const s: string;
const i: EVENT = s;

// NEGATIVE: the enum as a whole is not one of its members.
declare const ev: EVENT;
const j: "keydown" = ev;

// Same rule for a numeric enum member.
enum N {
  P = 1,
  Q = 2,
}
const k: 1 | 2 = N.P;
const l: number = N.P;
const m: 1 = N.P;
// NEGATIVE: a numeric literal that is not this member's value.
const n: 1 = N.Q;
// NEGATIVE: and one that is no member's value at all.
const o: 3 = N.P;
