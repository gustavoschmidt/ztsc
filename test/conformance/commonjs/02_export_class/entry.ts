import Foo = require("./cls");
const f = new Foo(3);
const y: Foo = f;
const n: number = f.x;
const bad: string = f.x;
