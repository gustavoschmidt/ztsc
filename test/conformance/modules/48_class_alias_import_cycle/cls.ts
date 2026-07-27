import type { Props } from "./types";

export class Thing {
  z: number = 1;
}

class C {
  prop: Thing = new Thing();
  method(a: number): string {
    return "";
  }
  // No return annotation: inferring one walks the body, which materializes
  // `Props` while `C`'s own instance type is still in progress. That is the
  // cycle — `Props` indexes straight back into `C`.
  use(p: Props) {
    return p.direct;
  }
}

export default C;
