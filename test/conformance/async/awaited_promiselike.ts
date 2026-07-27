export {};
// `await` unwraps `PromiseLike<T>` exactly like `Promise<T>`, to a fixed
// point through any nesting of the two.
declare const pl: PromiseLike<number[]>;
declare const p: Promise<string>;
declare const pp: Promise<Promise<number>>;
declare const plp: PromiseLike<Promise<number>>;
declare const ppl: Promise<PromiseLike<number>>;
declare const plu: PromiseLike<number> | undefined;

declare class Pool<T> {
  all(): PromiseLike<T[]>;
}

async function f() {
  const a: number[] = await pl;
  const b: string = await p;
  const c: number = await pp;
  const d: number = await plp;
  const e: number = await ppl;
  const g: number | undefined = await plu;
  const h: boolean[] = await new Pool<boolean>().all();

  // NEGATIVE: the unwrapped type is the payload, not the wrapper.
  const n1: null = await pl;
  const n2: null = await pp;
  const n3: null = await plp;
  const n4: null = await ppl;
  const n5: null = await plu;
  const n6: null = await new Pool<boolean>().all();
  // NEGATIVE: a non-thenable passes through untouched.
  const n7: null = await 1;
}

// An async function's inferred return type unwraps a returned PromiseLike.
async function g2(): Promise<number[]> {
  return pl;
}
async function g3() {
  return pl;
}
const r: null = g3();
