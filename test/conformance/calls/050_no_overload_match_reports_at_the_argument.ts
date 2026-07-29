// When no overload matches, tsc re-checks the LAST candidate with error
// reporting on and files the TS2769 where that check would have reported —
// the offending argument, or the offending PROPERTY of an object-literal
// argument — not at the callee. The calls below are spread over several lines
// so the reported line pins the anchor.

interface Opt {
  body: string;
  mode?: "a" | "b";
}

declare function send(url: string, opt: Opt): void;
declare function send(url: number, opt: Opt): void;

declare const wrongBody: number;

send(
  "u",
  {
    mode: "a",
    body: wrongBody,
  },
);

send(
  true as unknown as boolean,
  { body: "ok" },
);

// A single (non-overloaded) signature already reported at the property; the
// overload path must not regress to the callee.
declare function send1(url: string, opt: Opt): void;
send1(
  "u",
  {
    body: wrongBody,
  },
);
