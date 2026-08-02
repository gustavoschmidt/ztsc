// A `T[K]` target whose constraint declares `K` as `unknown` reduces to
// `unknown`, so anything is writable through it — distinct from a `K` the
// constraint does not declare at all, which gives the access no constraint
// and admits nothing.
interface Cfg {
  data: unknown;
  driverParam: unknown;
  n: number;
}

export function ok<T extends Cfg>(u: unknown, s: string, n: number) {
  const a: T["data"] = u;
  const b: T["driverParam"] = s;
  const cc: T["n"] = n;
  return [a, b, cc];
}

// A method whose parameter/return are written wide satisfies an interface
// that types them `T["data"]` / `T["driverParam"]` (drizzle's `Column` vs
// `DriverValueMapper`).
interface Mapper<TData, TDriverParam> {
  mapFromDriverValue(value: TDriverParam): TData;
  mapToDriverValue(value: TData): TDriverParam;
}
interface Col<T extends Cfg = Cfg> extends Mapper<T["data"], T["driverParam"]> {
}
declare abstract class Col<T extends Cfg = Cfg>
  implements Mapper<T["data"], T["driverParam"]>
{
  mapFromDriverValue(value: unknown): unknown;
  mapToDriverValue(value: unknown): unknown;
}

// A declared `number` key still rejects a `string`.
export function bad<T extends Cfg>(s: string) {
  const d: T["n"] = s;
  return d;
}
