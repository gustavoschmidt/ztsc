// Contextual return-type inference (tsc's `InferencePriority.ReturnType`): a
// generic call sitting in a typed context infers a type parameter that no
// argument constrained from the *expected* type. `collect`'s `G` is left
// unbound by a `never` argument, so `consume(collect(nv))` recovers `G` from
// `consume`'s parameter `Box<Small>` — the geojson `union(featureCollection(...))`
// shape — instead of falling back to `G`'s constraint (the wide `Shape` union).
// Argument inference still wins when an argument *does* constrain `G`.
interface Small {
  tag: "s";
}
interface Big {
  tag: "b";
}
type Shape = Small | Big;
interface Box<G extends Shape = Shape> {
  items: G[];
}
declare function collect<G extends Shape = Shape>(items: G[]): Box<G>;
declare function consume(b: Box<Small>): void;

declare const smalls: Small[];
consume(collect(smalls)); // clean: G=Small from the argument

declare const nv: never;
consume(collect(nv)); // clean: G recovered from consume's Box<Small> context

const boxed: Box<Small> = collect(nv); // clean: G from the annotation context
void boxed;

declare const bigs: Big[];
consume(collect(bigs)); // TS2345: argument wins (G=Big), Box<Big> not Box<Small>
