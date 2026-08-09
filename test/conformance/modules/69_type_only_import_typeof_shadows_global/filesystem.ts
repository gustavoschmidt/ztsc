// A module class whose name collides with a DOM global.
export declare class File {
  readonly uri: string;
  exists: boolean;
  open(): number;
}

export declare class Blob {
  readonly bytes: number;
}
