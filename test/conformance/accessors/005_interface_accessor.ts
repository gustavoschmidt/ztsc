// Interface accessor signatures: a get/set pair is one property; a
// get-only accessor is read-only.
interface P {
  get x(): number;
  set x(v: number);
  get y(): string;
}
declare const p: P;
const n: number = p.x;
p.x = 5;
const s: string = p.y;
p.y = "no";
