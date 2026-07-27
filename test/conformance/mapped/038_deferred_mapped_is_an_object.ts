// A mapped type is an object type by construction, deferred key set or not:
// it satisfies the `object` keyword and is a legal `for…in` operand.
declare function takesObject(o: object): void;

type MapIt<T> = { [P in keyof T]: T[P] };

function viaLibPartial<T>(p: Partial<T>): void {
  takesObject(p);
  for (const k in p) {
    void k;
  }
}

function viaOwnMap<T>(p: MapIt<T>): void {
  takesObject(p);
  for (const k in p) {
    void k;
  }
}

function viaConstrained<T extends { [key: string]: unknown }>(
  p: Partial<T>,
): void {
  takesObject(p);
}

// A concrete mapped type was always fine; keep it as the control.
type Conc = { [P in "a" | "b"]: number };
declare const conc: Conc;
takesObject(conc);

// @negative: primitives are still rejected, by both rules.
declare const n: number;
takesObject(n);
for (const k in n) {
  void k;
}

// @negative: a `keyof T` is a key union, not an object.
function viaKeyof<T>(k: keyof T): void {
  takesObject(k);
}

void viaLibPartial;
void viaOwnMap;
void viaConstrained;
void viaKeyof;
