interface Box { inner?: { value: number }; }
declare const b: Box | undefined;
const v: number | undefined = b?.inner?.value;
