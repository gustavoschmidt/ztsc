// `import A = N` is the ENTITY-NAME form: the alias denotes whatever `N`
// denotes, so `A.v` must type as the namespace member. Resolving the entity
// answered a GLOBAL symbol id that was then converted to global a SECOND
// time, which lands on an unrelated symbol in every file but the first — so
// this case only bites with the namespace in a non-leading file.
namespace N {
  export const v = 1;
}

import A = N;

export const probe: string = A.v;
export const missing = A.nope;
