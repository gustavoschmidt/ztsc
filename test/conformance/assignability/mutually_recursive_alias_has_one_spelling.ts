// A mutually recursive generic alias spells one type two ways: the reference
// the user writes expands to the union, while the one captured inside the
// partner alias's body — taken while the first alias was still materializing —
// stays a lazy reference. Both directions must still relate.

type Cond<T> = T extends unknown[] ? never : { q: T };
type R2<T> = Cond<T> | Tup<T>;
type Tup<T> = ["marker", ...R2<T>[]];

// `Tup<T>[1]` is the captured spelling; `R2<T>` written out is the expansion.
function d1<T>(v: R2<T>): Tup<T>[1] {
    return v;
}
function d2<T>(v: Tup<T>[1]): R2<T> {
    return v;
}
function d3<T>(v: Cond<T>): Tup<T>[1] {
    return v;
}

// …and the shapes the two spellings meet in element-wise.
function b1<T>(v: ["marker", ...R2<T>[]]): Tup<T> {
    return v;
}
function b4<T>(v: ["marker", ...R2<T>[]]): R2<T> {
    return v;
}
function b6<T>(v: ["marker", ...R2<T>[]]): Cond<T> | Tup<T> {
    return v;
}
