// The negative control for `090_generic_template_source_base_constraint.ts`:
// the base constraint is still a constraint.

interface Row {
  assetId: string;
  description: string | null;
}

type Excluded = `excluded.${keyof Row & string}`;
declare function ref<RE extends Excluded>(r: RE): RE;

// The wrong prefix.
export const n1 = <T extends keyof Row & string>(col: T) => ref(`included.${col}`);

// A hole whose constraint reaches keys the target does not have.
declare function ref2(r: 'excluded.assetId'): void;
export const n2 = <T extends keyof Row & string>(col: T) => ref2(`excluded.${col}`);

// An unconstrained hole is `string`-wide and fits nothing narrower.
export const n3 = <T>(col: T) => ref(`excluded.${col}`);

export {};
