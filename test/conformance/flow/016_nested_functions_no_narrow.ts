declare function get(): string | null;
let v: string | null = get();
function outer(): () => string {
  if (v === null) { throw ""; }
  return () => v;
}
