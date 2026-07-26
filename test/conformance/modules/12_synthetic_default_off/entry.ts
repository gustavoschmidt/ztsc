// Was authored as the negative control for the synthesized default (TS1192 on
// a default import of a module with no default export). That control is no
// longer expressible against the pinned oracle:
//
//   - the suite always runs `--moduleResolution bundler`, under which tsc's
//     effective `allowSyntheticDefaultImports` is ON;
//   - and this oracle version REMOVED the off switch — both
//     `esModuleInterop=false` and `allowSyntheticDefaultImports=false` are
//     rejected outright with TS5108 ("has been removed").
//
// So under every configuration the oracle accepts, this import is legal and
// `M` is the module namespace object. The case now pins that: clean. ztsc
// matches by defaulting the effective flag to ON (it always resolves with the
// bundler algorithm); it still honors an explicit `false` in a user tsconfig,
// which is a configuration the oracle itself refuses to run.
import M from "esmod";
M;
