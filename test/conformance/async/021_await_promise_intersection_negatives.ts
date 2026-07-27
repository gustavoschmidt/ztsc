// Awaiting through an intersection's thenable constituent must yield exactly
// that constituent's payload — not the intersection, and not `any`.
declare const rp: Promise<{ a: number }> & { resolve: (v: number) => void };
declare const notPromise: { a: number } & { b: string };

export async function wrongProp(): Promise<number> {
  const v = await rp;
  return v.b; // `b` is not on the payload
}

export async function payloadIsNotTheIntersection(): Promise<number> {
  const v = await rp;
  v.resolve(1); // `resolve` belongs to the un-awaited value
  return v.a;
}

export async function wrongPayloadType(): Promise<string> {
  const v = await rp;
  return v.a; // number, not string
}

export async function nonThenableStaysWhole(): Promise<number> {
  const v = await notPromise;
  return v.b; // string, not number
}
