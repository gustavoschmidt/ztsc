declare const items: { id: string; n: number | null }[];

// `f`'s return type is inferred, so `return acc` is checked before the loop
// body. Its flow walk crosses the loop's back edge to re-check the
// loop-carried `acc = …`, whose right-hand side reads the loop variable — so
// `it` is asked for its type before the `for..of` head has run.
function f() {
  let acc: string = "";
  for (const it of items) {
    acc = acc + it.id;
    const probe: null = it;
    if (it.n !== null) {
      const narrowed: number = it.n;
      const wrong: string = it.n;
    }
  }
  return acc;
}

// Same shape with a destructured binding.
function g() {
  let acc: string = "";
  for (const { id, n } of items) {
    acc = acc + id;
    const probeId: null = id;
    const probeN: null = n;
  }
  return acc;
}

// `for..in` keys stay `string` when demanded the same way.
function h() {
  let acc: string = "";
  for (const k in items) {
    acc = acc + k;
    const probeK: null = k;
  }
  return acc;
}
