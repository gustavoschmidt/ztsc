// A still-deferred conditional has the apparent members of its DEFAULT
// CONSTRAINT: the union of the true branch (instantiated under its own extends
// clause) and the false branch. A property both branches declare is readable.
export const compress = async <T extends Record<string, any> = never>(
  options: { encryptionKey: string } & ([T] extends [never]
    ? { metadata?: T }
    : { metadata: T }),
): Promise<string> => {
  return JSON.stringify(options.metadata || null) + options.encryptionKey;
};

// On its own, not only inside an intersection.
export const read = <T extends string>(
  o: T extends "a" ? { shared: number; onlyA: string } : { shared: number },
) => o.shared;

// NEGATIVE: a property only ONE branch declares is not readable.
export const bad = <T extends string>(
  o: T extends "a" ? { shared: number; onlyA: string } : { shared: number },
) => o.onlyA;
