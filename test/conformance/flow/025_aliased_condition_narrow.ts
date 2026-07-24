// TS4.4 "control flow analysis of aliased conditions and discriminants":
// a `const` alias of a narrowing expression narrows the subject through the
// alias. Mirrors the dogfood project's
//   `const projectMissing = project == null; projectMissing ? … : project.…`.
// Every access below must stay clean.
declare const project: { id: number } | null;
declare const value: string | number;

// nullish `== null` alias used in a ternary
function pick() {
  const missing = project == null;
  return missing ? "none" : project.id; // else-branch: project is non-null
}

// alias + early return
function guard() {
  const missing = project == null;
  if (missing) return 0;
  return project.id;
}

// `typeof` alias
function kindOf() {
  const isStr = typeof value === "string";
  return isStr ? value.length : value.toFixed(2);
}

// alias of alias
function chain() {
  const present = project != null;
  const stillPresent = present;
  return stillPresent ? project.id : 0;
}

// an effectively-const local (never reassigned) subject narrows too
function localSubject() {
  let p = project;
  const missing = p == null;
  return missing ? 0 : p.id;
}
