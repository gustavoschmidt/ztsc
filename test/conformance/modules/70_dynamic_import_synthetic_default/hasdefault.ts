// A real SOURCE module carrying ES-module syntax: it is known not to have a
// synthetic default, and it declares a real one.
export const other = 1;
export default function run(x: number): string {
  return String(x + other);
}
