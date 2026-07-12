export declare const VERSION: string;
export declare function parse(text: string, config: Config): number;
export interface Config {
  strict: boolean;
  depth: number;
}
