// An object literal with qualified enum-member computed keys (`{ [E.M]: v }`)
// must key those properties the same way a type literal / interface member does
// — an enum member's value identity is not carried in its type (the whole enum
// type), so both sides key by the member's source text. The literal therefore
// satisfies a target typed with the same computed keys, instead of collapsing
// to `{}` and reporting spurious TS2739 missing-property errors.

enum Breed {
  Nellore = 'NELLORE',
  Cross = 'CROSS',
}
enum Sex {
  Male,
  Female,
}

type Params = { weight: number };
type Cfg = {
  [Breed.Nellore]: { [Sex.Male]: Params; [Sex.Female]: Params };
  [Breed.Cross]: { [Sex.Male]: Params; [Sex.Female]: Params };
};

// Accepted: every computed key present, nested literals recurse.
const ok: Cfg = {
  [Breed.Nellore]: { [Sex.Male]: { weight: 1 }, [Sex.Female]: { weight: 2 } },
  [Breed.Cross]: { [Sex.Male]: { weight: 3 }, [Sex.Female]: { weight: 4 } },
};

// Rejected: a missing enum-keyed property is still a real TS2739.
const bad: Cfg = {
  [Breed.Nellore]: { [Sex.Male]: { weight: 1 }, [Sex.Female]: { weight: 2 } },
};

export { ok, bad };
