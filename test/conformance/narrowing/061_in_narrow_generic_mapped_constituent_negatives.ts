// Negatives for 060: treating a generic mapped constituent as "does not
// declare the name" must not make the TRUE branch lose the constituents that
// do, and the spread must still copy the concrete half's properties.

type AllKeys = "id" | "n";

type Row<T extends AllKeys> = Partial<Record<T, any>> &
  ({ id: string } | { tag?: string });

export function f<T extends AllKeys>(el: Row<T>) {
  if ("id" in el) {
    // Narrowed to the `{ id: string }` arm; `tag` is not on it.
    return el.tag;
  }
  return "";
}

export function g<T extends AllKeys>(el: Row<T>) {
  if (!("id" in el)) {
    // The false branch keeps only the `{ tag?: string }` arm.
    return el.id;
  }
  return "";
}

// The spread still copies the concrete constituents' properties: `tag` is
// present on the result, so a mismatching annotation reports.
export function h<T extends AllKeys>(el: Partial<Record<T, any>> & { tag: string }) {
  const r: { tag: number } = { ...el, id: "x" };
  return r;
}
