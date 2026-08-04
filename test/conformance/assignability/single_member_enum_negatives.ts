// The one-member-enum identity must not leak to enums that have more than
// one member, to a different enum, or to the raw value.
export enum One {
  A = "A",
}
export enum AlsoOne {
  A = "A",
}
export enum Two {
  A = "A",
  B = "B",
}

declare const one: One;
declare const two: Two;

// A multi-member enum is not any single member.
export const n1: Two.A = two;
export const n2: Two.A[] = [] as Two[];

// A different enum with the same shape is still a different enum.
export const n3: AlsoOne.A = one;

// The raw value is not the enum.
export const n4: One.A = "A";
export const n5: One = "A";
