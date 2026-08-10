export type Keyof<T extends {}> = keyof T extends string ? keyof T : never;

export interface NavState<PL extends {} = Record<string, object | undefined>> {
  key: string;
  routeNames: Keyof<PL>[];
}

export interface Helpers<PL extends {}, S extends NavState<any> = NavState> {
  dispatch(action: (state: S) => void): void;
  getParent(): void;
}

export type NavProp<
  PL extends {},
  RN extends keyof PL = Keyof<PL>,
  ID extends string | undefined = string | undefined,
  S extends NavState<any> = NavState<PL>,
  Opts extends {} = {},
> = Omit<Helpers<PL, S>, 'getParent'> & {
  id: ID;
  route: RN;
  options: Opts;
};

export declare function root<T extends {}>(nav: NavProp<T>): NavProp<T>;
