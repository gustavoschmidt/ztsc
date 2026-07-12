interface Opts { name: string; }
declare function setup(o: Opts): void;
setup({ name: "x", extra: 1 });
