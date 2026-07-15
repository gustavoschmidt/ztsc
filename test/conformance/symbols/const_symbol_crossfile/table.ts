import { entityKind } from "./entity";

export class Table {
  static readonly [entityKind]: string;
}

export class Sub extends Table {
  static readonly [entityKind]: string;
}
