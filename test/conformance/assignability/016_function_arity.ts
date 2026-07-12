type Cb = (a: number, b: string) => void;
declare const fewer: (a: number) => void;
const c1: Cb = fewer;
declare const more: (a: number, b: string, c: boolean) => void;
const c2: Cb = more;
