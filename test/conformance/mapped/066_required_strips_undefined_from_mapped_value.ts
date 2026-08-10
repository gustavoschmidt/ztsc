// `-?` removes `undefined` from the property type, not only the `?` flag
// (tsc's `CheckFlags.StripOptional` / `removeMissingOrUndefinedType`).
// The source here is itself a mapped type, so its property type already
// carries the `| undefined` that `Pick`'s `T[K]` value baked in.
interface Props {
  image?: { source: string };
  other?: number;
}

type OnlyImage = Required<Pick<Props, "image">>;

declare const a: OnlyImage;
const a1: { source: string } = a.image;
const a2: string = a.image.source;

// The same through an intersection, the shape a destructured parameter uses.
type Both = Required<Pick<Props, "image">> & Omit<Props, "image">;
declare const b: Both;
const b1: string = b.image.source;

function f({ image }: Both) {
  return image.source;
}
declare const f1: string;
const f2: string = f(b);

// A REQUIRED property declared `| undefined` keeps its undefined under `-?`:
// tsc gates the strip on the source symbol being optional.
interface Keep {
  k: string | undefined;
}
declare const k: Required<Keep>;
const kbad: string = k.k; // TS2322
