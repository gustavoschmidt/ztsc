// Awaited<T> over concrete promises resolves (no deferred-conditional leak):
// single and nested unwrap, union distribution, and the `any` check taking
// both branches (Awaited<any> = any).
type A1 = Awaited<Promise<number>>;
const c1: number = null as unknown as A1;
type A2 = Awaited<Promise<Promise<string>>>;
const c2: string = null as unknown as A2;
type A3 = Awaited<number | Promise<boolean>>;
const c3: number | boolean = null as unknown as A3;
type A4 = Awaited<any>;
const c4: number = null as unknown as A4; // any is assignable everywhere
const bad: string = null as unknown as A1; // TS2322
