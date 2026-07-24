// Negative controls for TS4.4 aliased-condition narrowing: the cases where
// tsc does NOT narrow through the alias, so the guarded access still errors.
// Verified against tsc 5.9.3.
declare const project: { id: number } | null;
declare function get(): { id: number } | null;

// a `let` alias never narrows — only a `const` alias does
function letAlias() {
  let missing = project == null;
  return missing ? "none" : project.id;
}

// an explicit type annotation on the alias disables narrowing
function annotated() {
  const missing: boolean = project == null;
  return missing ? "none" : project.id;
}

// a non-narrowing initializer does not narrow the subject
function plainBool(flag: boolean) {
  const missing = flag;
  return missing ? "none" : project.id;
}

// reassigning the subject between the alias and its use invalidates the alias
function subjectReassigned(p: { id: number } | null) {
  const missing = p == null;
  p = get();
  return missing ? "none" : p.id;
}
