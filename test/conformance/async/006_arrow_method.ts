const ok = async (n: number): Promise<number> => n;
const bad = async (n: number): Promise<number> => "x";
class C {
  async good(): Promise<number> { return 1; }
  async wrong(): Promise<number> { return "x"; }
}
