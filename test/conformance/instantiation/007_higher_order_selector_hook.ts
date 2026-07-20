// Higher-order rewrite (M20a): a generic interface whose type param is used
// only inside a call signature that ALSO declares its own type param — the
// react-redux `TypedUseSelectorHook<TState>` shape. Instantiating the interface
// must substitute the outer `TState` inside the signature (the selector's
// parameter) while keeping the signature callable and its own `<S>` intact.
// Before the rewrite the interface was judged concrete (the higher-order sig
// was skipped), so `TState` stayed unsubstituted and every `s.<prop>` failed.
interface TypedUseSelectorHook<TState> {
  <S>(selector: (state: TState) => S): S;
}
type RootState = { count: number; name: string };
declare const useSel: TypedUseSelectorHook<RootState>;

const n: number = useSel((s) => s.count); // clean: s is RootState, S=number
const s1: string = useSel((s) => s.name); // clean
const bad: string = useSel((s) => s.count); // TS2322: number not string
const miss = useSel((s) => s.elevation); // TS2339: elevation not on RootState
