interface ET {
  listen: number;
}
interface EL extends ET {
  accessKey: string;
}
interface Marker {
  mk: number;
}
interface Ev {
  target: ET | null;
  kind: string;
}

declare function nul<X>(): X;

export function f<T extends EL>() {
  // `null & T` is left unreduced (T could still resolve to anything under its
  // constraint), and its nullish half contributes no members — so it does not
  // satisfy an INTERSECTION target. Wrapped in a property so the oracle picks
  // the same diagnostic code ztsc does; the bare form is TS2739/TS2740.
  const n = nul<null & T>();
  const wn = { p: n };
  const a1: { p: ET & EL } = wn; // error
  const a2: { p: Marker & EL } = wn; // error
  const a3: EL = n; // OK: a plain target is reached through T
  const a4: ET = n; // OK
  void a1;
  void a2;
  void a3;
  void a4;

  const u = nul<undefined & T>();
  const wu = { p: u };
  const b1: { p: ET & EL } = wu; // error
  void b1;

  // A non-nullish intersection still relates through its constituents.
  const c1: ET & EL = nul<ET & T>(); // OK
  const d1: ET & EL = nul<{} & T>(); // OK
  const e1: Marker & EL = nul<Marker & T>(); // OK
  void c1;
  void d1;
  void e1;

  // Two intersections are compared through their MERGED property sets: the
  // target demands `target: (ET | null) & EL`, which the source's
  // `{ target: T }` half does not supply on its own.
  const ev = nul<Ev & { target: T }>();
  const g1: Ev & { target: EL } = ev; // error
  const g2: { target: EL } = ev; // OK: no merging in a plain target
  void g1;
  void g2;
}
