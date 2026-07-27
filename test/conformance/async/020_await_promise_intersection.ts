// `await` reads its value type off the `then` member, so an INTERSECTION
// awaits through its thenable constituent. The promise-with-resolvers shape
// `Promise<T> & { resolve; reject }` therefore awaits to `T`.
type MaybePromise<T> = T | Promise<T>;

type ResolvablePromise<T> = Promise<T> & {
  resolve: [T] extends [undefined]
    ? (value?: MaybePromise<Awaited<T>>) => void
    : (value: MaybePromise<Awaited<T>>) => void;
  reject: (error: Error) => void;
};

declare const rp: ResolvablePromise<{ a: number } | null>;
declare const plain: Promise<{ b: string }> & { tag: 1 };

export async function readResolvable(): Promise<number | undefined> {
  const scene = await rp;
  return scene?.a;
}

export async function readPlain(): Promise<string> {
  const v = await plain;
  return v.b;
}

// the non-thenable half is still reachable on the un-awaited value
export function resolveIt(): void {
  rp.resolve({ a: 1 });
  rp.reject(new Error("x"));
}

// an intersection with no thenable constituent awaits to itself
declare const notPromise: { a: number } & { b: string };
export async function readNonThenable(): Promise<string> {
  const v = await notPromise;
  return v.b;
}
