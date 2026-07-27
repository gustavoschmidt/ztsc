// The TS2367/TS2678 overlap test resolves a type parameter to its constraint,
// so comparing a generic value against a literal of its constraint is fine.
type Kind = "rectangle" | "diamond" | "line" | "arrow" | "text";

function eq<T extends Kind>(t: T) {
  if (t === "text") {
    return 1;
  }
  if (t === "line" || t === "arrow") {
    return 2;
  }
  return 3;
}

// A switch after a narrowing that produced `("line" & T) | ("arrow" & T)`.
function sw<T extends Kind>(t: T) {
  if (t === "line" || t === "arrow") {
    // narrowed to an intersection with the parameter
  }
  switch (t) {
    case "rectangle":
      return 1;
    case "diamond":
      return 2;
    default:
      return 3;
  }
}

// An unconstrained parameter overlaps everything — it could be instantiated
// to the other operand's type.
function unconstrained<T>(t: T) {
  return t === "anything";
}

// @negative: a constrained parameter still rejects a disjoint literal.
function disjoint<T extends "a" | "b">(t: T) {
  return t === "zzz";
}

// @negative: and a disjoint switch case.
function disjointSwitch<T extends "a" | "b">(t: T) {
  switch (t) {
    case "zzz":
      return 1;
    default:
      return 2;
  }
}

// @negative: the constraint's domain still matters.
function wrongDomain<T extends Kind>(t: T) {
  return t === 42;
}

void eq;
void sw;
void unconstrained;
void disjoint;
void disjointSwitch;
void wrongDomain;
