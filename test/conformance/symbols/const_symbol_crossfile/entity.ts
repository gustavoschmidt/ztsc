export declare const entityKind: unique symbol;
export declare const other: unique symbol;

export interface DrizzleEntity {
  [entityKind]: string;
}
