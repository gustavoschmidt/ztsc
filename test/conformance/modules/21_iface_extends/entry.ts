import { Base } from "./base";
interface Derived extends Base {
  extra: string;
}
const d: Derived = { id: 1, extra: "x" };
const bad: Derived = { extra: "x" };
