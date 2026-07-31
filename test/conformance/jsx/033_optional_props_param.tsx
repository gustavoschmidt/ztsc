declare namespace JSX {
  interface Element {}
  interface IntrinsicElements {}
}

// A component whose props parameter is optional at the call site — `p?: Props`
// or a destructured parameter with a `= {}` default — still has `Props` as its
// JSX attributes target: tsc's `intersectTypes(IntrinsicAttributes, Props |
// undefined)` distributes to `(IntrinsicAttributes & Props) | undefined`, and a
// JSX attributes object is never `undefined`, so the object constituent is what
// every attribute is checked against.
type Opt = { onPick?: () => void };
type Req = { req: string };

declare const maybeFn: (() => void) | undefined;

declare function DefaultedOpt({ onPick }?: Opt): JSX.Element;
declare function QuestionOpt(p?: Opt): JSX.Element;
declare function DefaultedReq(p?: Req): JSX.Element;

// an optional prop still admits an explicitly-passed `undefined`
export const a = <DefaultedOpt onPick={maybeFn} />;
export const b = <QuestionOpt onPick={maybeFn} />;

// ... and a required prop is still required, and excess is still excess
export const c = <DefaultedReq req="x" />;
export const d = <DefaultedOpt onPick={() => {}} />;
