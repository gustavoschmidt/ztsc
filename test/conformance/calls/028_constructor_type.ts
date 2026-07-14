class Animal { move(): void {} }
type Maker = new () => Animal;
declare const M: Maker;
const x: Animal = new M();
const bad: string = new M();
type AbsMaker = abstract new () => Animal;
declare const AM: AbsMaker;
const cm: AbsMaker = M;
