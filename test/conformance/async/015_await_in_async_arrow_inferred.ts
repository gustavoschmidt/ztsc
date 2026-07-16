// `await` inside an async arrow whose return type is *inferred* must be
// legal even though the enclosing function is not async: the arrow's
// return-type-inference probe has to judge await-legality against the
// arrow's own async context, not the enclosing non-async one (which
// produced a TS1308 false positive whose file placement was
// checker-order dependent).
function refresh(p: Promise<number>): Promise<number> {
  return p.then(async (data) => {
    const doubled = await Promise.resolve(data * 2);
    return doubled + 1;
  });
}
const r: Promise<number> = refresh(Promise.resolve(1));
