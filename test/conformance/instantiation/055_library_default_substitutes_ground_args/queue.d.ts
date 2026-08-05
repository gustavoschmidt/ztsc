export declare class Job<D = any, R = any, N extends string = string> {
  private brand: [D, R];
  name: N;
  data: D;
}

type ExtractName<T, Def extends string> = T extends Job<any, any, infer N> ? N : Def;
type ExtractData<T, Def> = T extends Job<infer D, any, any> ? D : Def;

export declare class Queue<
  DataTypeOrJob = any,
  DefaultNameType extends string = string,
  DataType = ExtractData<DataTypeOrJob, DataTypeOrJob>,
  NameType extends string = ExtractName<DataTypeOrJob, DefaultNameType>,
> {
  add(name: NameType, data: DataType): void;
}

// A default whose earlier positions are NOT ground keeps the lenient,
// unsubstituted path: `Holder<T>`'s `Inner` is a complex default over an
// abstract argument.
export declare class Holder<T, Inner = ExtractData<T, T>> {
  take(v: Inner): void;
}
