import {type Rec} from './rec'

// Materializes `Rec<string, unknown>` — and with it the `origin` tag on the
// interned `{ [s: string]: unknown }` that `use.ts`'s overload parameter also
// instantiates to.
export const seeded: Rec<string, unknown> = {}
