import "jestdom";
declare const expect: jest.Expect;
const el = 1;
const a: void = expect(el).toBeInDoc();
const bad: number = expect(el).hasVal(2);
const c: void = expect(el).toBe(el);
expect(el).hasVal("x");
