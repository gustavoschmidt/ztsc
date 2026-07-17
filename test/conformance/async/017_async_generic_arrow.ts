// `async <T>(params) => body` — a generic async arrow must parse so its
// parameters and body identifiers stay in scope.
interface In<T> { field: { build(v: T): string }; registryValue: T; }

const correct = async <T>({ field, registryValue }: In<T>): Promise<number> => {
  const payload = field.build(registryValue);
  const response = payload.length;
  return response > 0 ? response : 0;
};

void correct;
