// A block body with no `return` whose endpoint is unreachable infers `never`,
// not `void` — so it satisfies any expected return type.
declare function mockImpl(fn: () => [number, string]): void;

mockImpl(() => {
  throw new Error("boom");
});

const g = () => {
  throw new Error("boom");
};
export const h: () => number = g;

function fail(): never {
  throw new Error("boom");
}

// Terminal in the MIDDLE of the list still kills the endpoint.
const mid = () => {
  throw new Error("boom");
  const dead = 1;
};
export const m: () => string = mid;

// An exhaustive `if`/`else` where both arms throw.
const both = (b: boolean) => {
  if (b) {
    throw new Error("a");
  } else {
    throw new Error("b");
  }
};
export const bo: (b: boolean) => boolean = both;

// A body that CAN fall off the end still infers `void`.
const plain = () => {
  const x = 1;
};
export const p: () => void = plain;

export const f: () => never = fail;
