export interface Rec {
  kind?: "rec";
  record: number;
}
export interface Img {
  kind?: "img";
  images: number;
}
export declare function isRec<V>(v: V): v is V & Rec;
export declare function isRecPlain(v: unknown): v is Rec;
export declare function assertRec<V>(v: V): asserts v is V & Rec;
