// The weak-type rule (tsc's `isWeakType` / `hasCommonProperties`, TS2559).
// A target whose properties are ALL optional, with no call/construct
// signatures and no index signature, is satisfied structurally by anything at
// all — so TypeScript adds the requirement that source and target share a
// property name. Without it, a callback argument lands on an options-bag
// overload (`fs.watch(path, listener)`) and its parameters are never
// contextually typed.

interface Weak {
  a?: number;
  b?: string;
}
declare const other: { c: number; d: string };
declare const fn: () => void;
declare const ok: { a: number; c: string };

declare function takeWeak(w: Weak): void;
takeWeak(other); // TS2559
takeWeak(fn); // TS2559
takeWeak(ok);

// An empty source has no properties AND no signatures: tsc's gate excludes it.
declare const empty: {};
takeWeak(empty);

// Assignment position reports the same code.
const w1: Weak = other; // TS2559
const w2: Weak = ok;

// A union target is judged constituent by constituent.
declare function takeUnion(u: Weak | string): void;
takeUnion(other); // TS2345
takeUnion('s');

// Not weak: a required property. The ordinary structural failure stands.
interface NotWeak {
  a?: number;
  r: string;
}
const n1: NotWeak = other; // TS2739

// Not weak: call signature.
interface Callable {
  (): void;
  a?: number;
}
declare function takeCallable(x: Callable): void;
takeCallable(fn);

// Not weak: index signature — it knows every name.
interface Indexed {
  a?: number;
  [k: string]: unknown;
}
const i1: Indexed = other;

// An intersection target is weak only when EVERY constituent is; a
// constituent is never judged on its own.
declare function takeMixed(m: { a: number } & { b?: string }): void;
takeMixed(ok);
declare function takeBothWeak(m: { a?: number } & { b?: string }): void;
takeBothWeak(other); // TS2559

// A FRESH object literal belongs to the excess-property check, which runs
// first and answers for every such source.
const f1: Weak = { c: 1 }; // TS2353, not the weak rule
takeWeak({ a: 1 });
takeWeak({});

// The overload-selection case the rule exists for: an options bag whose
// object constituent is weak must not swallow a listener argument.
interface WatchOptions {
  encoding?: string | undefined;
  persistent?: boolean | undefined;
}
type Listener = (event: 'rename' | 'change', filename: string | null) => void;
declare function watch(path: string, options?: WatchOptions | null, listener?: Listener): number;
declare function watch(path: string, listener: Listener): number;
watch('d', (eventType, filename) => {
  const e: 'rename' | 'change' = eventType;
  const f: string | null = filename;
  return [e, f];
});
