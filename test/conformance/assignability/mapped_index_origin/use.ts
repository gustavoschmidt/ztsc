import {type Rec} from './rec'

declare function pick<V>(o: {[s: string]: V}): V
declare function pick(o: {}): number

export function each<T extends Rec<string, string>>(
  d: Rec<keyof T & string, string | string[]>,
): void {
  const v = pick(d)
  // `v` is the second overload's `number` for tsc — the first overload's
  // parameter is a bare index signature, which a still-generic mapped type
  // does not satisfy. Reading `length` off it is TS2339 either way; what the
  // case pins is that the SAME diagnostic is reported at every `--checkers=N`
  // and in every file order, which is what the determinism test checks.
  const n: number = v
  void n
}
