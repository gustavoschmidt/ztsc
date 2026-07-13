const obj = { a: 1, b: 2 };
const ks: string[] = Object.keys(obj);
const vs: any[] = Object.values(obj);
const es: [string, any][] = Object.entries(obj);
const merged: any = Object.assign({}, obj, { c: 3 });
const frozen = Object.freeze(obj);
const fa: number = frozen.a;
const first: string = ks[0];
