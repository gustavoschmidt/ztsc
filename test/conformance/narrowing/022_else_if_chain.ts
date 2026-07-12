type V = string | number | boolean | null;
function f(v: V): string {
  if (v === null) { return "null"; }
  else if (typeof v === "string") { return v; }
  else if (typeof v === "number") { return "n"; }
  else { const b: boolean = v; return "b"; }
}
