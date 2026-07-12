function f(x: string | number): "wide";
function f(x: string): "narrow";
function f(x: string | number): string { return "wide"; }
const r: "wide" = f("a");
