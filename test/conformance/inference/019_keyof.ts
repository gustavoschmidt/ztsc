interface Point { x: number; y: number; }
declare const k: keyof Point;
const ok: "x" | "y" = k;
const bad: "x" = k;
