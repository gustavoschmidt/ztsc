// A distributive conditional whose check is a WHOLE ENUM distributes over the
// enum's member types when the extends clause names members of that same enum.
//
// tsc's declared type of `E` IS `E.A | E.B | …`, so `Exclude<E, E.A>` really
// does subtract a member there. ztsc keeps an enum as one nominal type, so
// `E extends E.A` simply answered false and `Exclude` handed the whole enum
// back — immich's `ConcurrentQueueName = Exclude<QueueName, QueueName.Backup
// Database | …>` still carried all four excluded queues, which only became
// visible (as four missing properties) once `Record<E, V>` started
// materializing named members.
enum E {
  A = 'AV',
  B = 'BV',
  C = 'CV',
}

type Without<T, U> = T extends U ? never : T;
type Only<T, U> = T extends U ? T : never;
type Rec<K extends string | number | symbol, V> = { [P in K]: V };

type Sub = Without<E, E.C>;
type Just = Only<E, E.A | E.C>;

declare const s: Sub;
export const s1: E.A | E.B = s;
export const s2: E.C = s;

declare const j: Just;
export const j1: E.A | E.C = j;
export const j2: E.B = j;

// The key set of a record over the narrowed domain loses exactly the excluded
// member.
declare const sub: Rec<Sub, number>;
export const ok: Rec<E.A | E.B, number> = sub;
export const missing: Rec<E, number> = sub;

// A conditional that does NOT mention a member of the enum is unchanged: the
// answer is the same for the enum and for every member, and the result keeps
// its `E` spelling.
type Stringly = E extends string ? E : never;
export const st: E = null as any as Stringly;
