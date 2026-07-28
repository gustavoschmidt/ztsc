// This arrow's body is walked exactly once in the whole program: while
// `entry.ts` materializes `dep`'s type from inside an overload probe. Its
// diagnostic therefore has no second chance to be filed.
export const dep = (n: number): number => {
  const bad: number = "not a number";
  return n + 1;
};
