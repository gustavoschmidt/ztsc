// A literal ARGUMENT whose contextual type — the parameter — names a literal
// domain it belongs to loses its FRESHNESS before inference sees it. tsc does
// this in `checkExpressionWithContextualType`, with the comment "such that
// contextually typed literals always preserve their literal types (otherwise
// they might widen during type inference)"; `getWidenedLiteralType` only
// widens a fresh literal, so a regularized one survives `getCovariantInference`
// whatever the top-level/return-position rules say.
//
// That single test separates two shapes that otherwise look identical.
// `on(eventName: K | keyof T, listener: Listener<K, T>)` — `node:events`,
// hence chokidar's `FSWatcher` — infers `K = "add"` because the union has a
// string-literal constituent for `"add"` to match. It has to: `Listener<K, T>`
// is a conditional on `K extends keyof T`, and a widened `string` reduces it
// to `never`, so every listener written for a typed emitter lost its parameter
// types to TS7006. `useState(initial: S | (() => S))` still widens `false` to
// `boolean`, because nothing in THAT union is a literal.

interface M {
  add: [path: string, size?: number];
  error: [e: unknown];
  ready: [];
}

type Key<K, T> = T extends [never] ? string | symbol : K | keyof T;
type Listener<K, T> = T extends [never] ? (...a: any[]) => void
  : K extends keyof T ? (T[K] extends unknown[] ? (...args: T[K]) => void : never)
  : never;

declare class Emitter<T> {
  on<K>(eventName: Key<K, T>, listener: Listener<K, T>): this;
}

declare const e: Emitter<M>;
e.on('ready', () => {});
e.on('add', (p) => p.toUpperCase());
e.on('error', (x) => String(x));

// The literal is KEPT when the parameter union offers a literal to match.
declare function unioned<K>(k: K | 'other'): K[];
const u = unioned('add');
const uk: 'add'[] = u;

// … and when a `keyof` names the domain.
declare function keyed<K>(k: K | keyof M): K[];
const kk: 'add'[] = keyed('add');

// It still WIDENS with nothing to match: a bare parameter, a parameter buried
// in a wrapper, and a union whose other member is not a literal.
declare function bare<K>(k: K): K[];
const bw: string[] = bare('add');

declare function wrapped<K>(k: { v: K }): K[];
const ww: string[] = wrapped({ v: 'add' });

declare function useState<S>(initial: S | (() => S)): [S, (n: S) => void];
const [, setFlag] = useState(false);
setFlag(true);

export { u, uk, kk, bw, ww };
