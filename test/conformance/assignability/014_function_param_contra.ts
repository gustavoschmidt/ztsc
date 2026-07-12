type Handler = (x: string | number) => void;
declare const wide: (x: string | number | boolean) => void;
const h1: Handler = wide;
declare const narrow: (x: string) => void;
const h2: Handler = narrow;
