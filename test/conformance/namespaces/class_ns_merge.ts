class C {
  m(): number {
    return 1;
  }
}
namespace C {
  export const s = 5;
}

const r: number = new C().m() + C.s;
