// An array literal `as const` becomes a readonly tuple: elements keep their
// literal types and positions, and writing to one is TS2540.
const arr = [1, "x"] as const;
const first: 1 = arr[0];
const second: "x" = arr[1];
arr[0] = 9;
