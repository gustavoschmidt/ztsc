// Higher-order rewrite (M20a): an own type param whose *default* (and
// constraint) references the enclosing interface's param — react-redux's
// `useDispatch`/`withTypes` shape `<AD extends Dispatch = Dispatch>(): AD`.
// A no-arg call must resolve the own param to the *substituted* default, so the
// returned value has the concrete base type (and stays callable/usable). The
// fresh symbol minted for `AD` carries the map-substituted default `Base`.
interface Dispatch {
  (action: { type: string }): void;
}
interface Factory<TBase extends Dispatch> {
  <AD extends TBase = TBase>(): AD;
  withBase<TOverride extends TBase>(): Factory<TOverride>;
}
declare const f: Factory<Dispatch>;

const d = f(); // AD defaults to Dispatch
d({ type: "x" }); // clean: Dispatch is callable
const bad: string = f(); // TS2322: Dispatch not string

const sub = f.withBase<Dispatch>();
const d2 = sub();
d2({ type: "y" }); // clean: withBase result still yields a callable dispatch
