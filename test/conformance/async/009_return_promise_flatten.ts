async function f(): Promise<number> { return Promise.resolve(1); }
async function g(): Promise<number> { return Promise.resolve("x"); }
async function infer() { return Promise.resolve("a"); }
const s: Promise<string> = infer();
