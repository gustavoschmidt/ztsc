type Op = (a: number, b: number) => number;
const add: Op = (a, b) => a + b;
const bad: Op = (a, b) => "s";
