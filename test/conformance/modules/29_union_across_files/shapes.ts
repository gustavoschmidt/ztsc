export interface Circle { kind: "circle"; radius: number; }
export interface Square { kind: "square"; side: number; }
export type Shape = Circle | Square;
