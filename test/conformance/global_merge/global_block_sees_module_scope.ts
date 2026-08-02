// A `global { … }` block nested in `declare module "spec"` resolves names by
// walking OUT into the module body, exactly as tsc's `resolveName` walks the
// node parent chain — the block's parent node is the module declaration, not
// the source file. Real `@types/node` `events.d.ts` is this shape: `type
// Key<…>` / `type Args<…>` live in the `declare module "events"` body and are
// used from `global { namespace NodeJS { interface EventEmitter … } }`.
declare module "evts" {
  type Key<K> = K | string;
  interface Opts {
    verbose: boolean;
  }
  global {
    namespace Emitters {
      interface Emitter<K> {
        on(k: Key<K>, o: Opts): void;
        readonly last: Opts;
      }
    }
  }
  export {};
}

declare const em: Emitters.Emitter<number>;
em.on(1, { verbose: true });
em.on("x", { verbose: true });
const good: boolean = em.last.verbose;
// The block's members really are typed, not `any`:
const bad: string = em.last.verbose;
em.on(1, { verbose: 1 });
