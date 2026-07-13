async function outer() {
  function inner() {
    const x = await Promise.resolve(1);
  }
}
