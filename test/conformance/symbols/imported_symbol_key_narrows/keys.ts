export declare const PAGINATION: unique symbol;
export declare const OTHER: unique symbol;

export interface Paged {
  [PAGINATION]?: { total: number };
  [OTHER]?: { total: number };
}
