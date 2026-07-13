const p: Promise<number> = Promise.resolve(5);
const chained: Promise<string> = p.then((n) => n.toFixed(2));
const rejected: Promise<any> = Promise.reject("err");
const all: Promise<number[]> = Promise.all([1, 2, 3]);
