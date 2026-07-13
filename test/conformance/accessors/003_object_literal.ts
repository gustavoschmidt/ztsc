// An object-literal getter gives a property of the getter's return type,
// and a get-only accessor is read-only.
const o = { get x() { return 1; } };
const n: number = o.x;
const bad: string = o.x;
o.x = 5;
