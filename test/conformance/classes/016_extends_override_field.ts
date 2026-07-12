class Base { value: string | number = 1; }
class Narrow extends Base { value: number = 2; }
const n = new Narrow();
const v: number = n.value;
