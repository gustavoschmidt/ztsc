// An element access whose KEY is a whole enum. ztsc models an enum as one
// nominal type while tsc models it as the union of its member types, so the
// key is neither string-like nor number-like and the access fell through to
// `any` — poisoning every read off the result and the inferred return type
// of the function holding it. tsc computes `getIndexedAccessType`, which
// distributes over the members.
enum JobName {
  A = "a",
  B = "b",
}
enum JobStatus {
  Success = "success",
  Skipped = "skipped",
}
type Item = { label: string; handler: () => JobStatus };

declare const handlers: { [K in JobName]?: Item };
declare const key: string;

export function run() {
  const item = handlers[key as JobName];
  if (!item) {
    return JobStatus.Skipped;
  }
  return item.handler();
}

// The access is `Item | undefined`, so the guard is what makes the member
// readable and the inferred return type is `JobStatus`.
export const ok: JobStatus = run();

// Negative control: it is not `any` — a wrong annotation still reports.
export const bad: number = run();

// Negative control: a numeric enum key reads the numeric domain the same
// way, and the property is optional there too.
enum Idx {
  Zero,
  One,
}
declare const table: { [K in Idx]: string };
declare const i: Idx;
export const cell: string = table[i];
export const cellBad: number = table[i];
