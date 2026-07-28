import { twice, label, Opts } from "valpkg";
import one from "valpkg-one";

// `twice`/`label` are not members of the export-assigned entity — they are
// properties of its TYPE, which is where tsc looks next.
const a: number = twice(1);
const b: string = label;
// ... and the same resolution has to survive a re-export chain.
const c: number = one(2);
// A real namespace member still resolves the way it always did.
const d: Opts = { deep: true };

// Negative controls: the property's declared type is kept, and a name that is
// neither a namespace member nor a property of the value stays an error.
const bad: string = twice(1);
const nope = (twice as unknown as { q: number }).q(1);

export { a, b, c, d, bad, nope };
