// A hand-authored dependency .d.ts. Under skipLibCheck these declarations are
// still parsed/bound/linked so their types flow into entry.ts, but any
// type-checking diagnostic located HERE is suppressed (matching tsc).
declare namespace NS {
  export interface Point {
    x: number;
    y: number;
  }
}

// Semantic error located in the .d.ts (TS2694): suppressed under skipLibCheck.
export type Broken = NS.DoesNotExist;

export declare const origin: NS.Point;
export declare function needsString(s: string): void;
