type Getter = () => string | number;
declare const g1: () => string;
const a: Getter = g1;
declare const g2: () => string | number | boolean;
const b: Getter = g2;
