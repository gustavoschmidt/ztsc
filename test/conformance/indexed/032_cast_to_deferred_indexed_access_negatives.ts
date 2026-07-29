// The one shape tsc still rejects: the object constraint reduces `T[K]` to
// `number` through its mapped template, and `string` does not overlap that.
// ztsc concedes this whole family (see indexed/031) rather than reduce the
// access structurally, which would reject the shapes tsc leaves deferred.
export {};

function k<T extends Record<keyof T, number>, K extends keyof T>(v: T[K]) {
  return v as string; // TS2352
}

// A cast NOT involving a deferred access is still checked normally, so the
// concession is scoped to the deferred operand.
function m<T extends Record<keyof T, number>>(v: T) {
  return v as string; // TS2352
}
