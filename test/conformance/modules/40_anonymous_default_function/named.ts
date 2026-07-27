// A *named* default-exported function still binds its own name locally.
export default function helper(a: number) {
  return helper2(a);
}
function helper2(a: number) {
  return a;
}
