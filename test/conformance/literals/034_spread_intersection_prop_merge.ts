// A spread of an INTERSECTION contributes, for each name, the intersection of
// every constituent's declaration — not the last constituent's alone.
type Opts = { width?: number; height?: number; mirror?: true } & {
  height?: string | number;
  width?: string | number;
  strokeWidth?: string | number;
  fill?: string;
};

declare function createIcon(opts?: number | Opts): void;
declare const base: Opts;

// `height`/`width` must stay `number` (`number & (string | number)`), so the
// spread result is still an `Opts`.
createIcon({ ...base, strokeWidth: 1.5 });
createIcon(base);

// The merge must not lose a name only one constituent declares.
const merged = { ...base };
const f: string | undefined = merged.fill;
const h: number | undefined = merged.height;
void f;
void h;

// NEGATIVE: the merged `height` really is the NARROW `number`, so the wide
// declaration is not what the spread produced.
const bad: string | undefined = merged.height;
void bad;

// NEGATIVE: a name only the narrow constituent declares keeps its type.
const badMirror: false | undefined = merged.mirror;
void badMirror;

// The optional flag survives only when every declaring constituent is optional.
type Req = { r: number } & { r?: number };
declare const req: Req;
const spreadReq = { ...req };
const r: number = spreadReq.r;
void r;
