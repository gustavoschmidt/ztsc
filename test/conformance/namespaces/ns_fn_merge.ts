function F(): number {
  return 1;
}
namespace F {
  export const prop = 5;
}

const r: number = F() + F.prop;
