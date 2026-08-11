// Overload resolution failed: the TS2769 belongs on the ARGUMENT that failed,
// not on something inside it. Here the failing argument is ITSELF a failing
// call, so it files its own TS2345 several lines deeper; taking the first
// diagnostic the re-check produced anchored the TS2769 there.
declare function wrap(x: number): number;

interface Router {
  post(a: string, b: string, c: (x: string) => void): void;
  post(a: string, b: boolean, c: (x: string) => void): void;
}
declare const r: Router;

r.post(
  "x",
  wrap(
    "nope"
  ),
  (x: string) => {}
);
