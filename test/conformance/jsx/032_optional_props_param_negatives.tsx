declare namespace JSX {
  interface Element {}
  interface IntrinsicElements {}
}

// Negatives: an optional props PARAMETER does not make the props themselves
// optional — required members are still required and unknown members are still
// excess — and a required prop still rejects a possibly-undefined value.
type Req = { req: string };
type Opt = { onPick?: () => void };

declare const maybeFn: (() => void) | undefined;

declare function DefaultedReq(p?: Req): JSX.Element;
declare function DefaultedOpt({ onPick }?: Opt): JSX.Element;
declare function DefaultedBoth(p?: { req: () => void; onPick?: () => void }): JSX.Element;

export const a = <DefaultedReq />; // error: 'req' is missing
export const b = <DefaultedReq req="x" bogus={1} />; // error: excess 'bogus'
export const c = <DefaultedOpt onPick={1} />; // error: number is not () => void
export const d = <DefaultedBoth req={maybeFn} />; // error: required prop, undefined
