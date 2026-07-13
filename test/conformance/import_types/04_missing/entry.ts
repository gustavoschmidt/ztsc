type A = import("./nope").Foo;
type B = import("./dep").Bar;
const ok: import("./dep").Foo = { a: 1 };
