export interface Box<T> { value: T; }
export function wrap<T>(value: T): Box<T> {
  return { value: value };
}
