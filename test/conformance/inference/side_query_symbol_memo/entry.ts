// A context-sensitive object-literal argument is checked TWICE: once as a
// speculative probe, with every still-free type parameter standing in as
// `any`, and then authoritatively with the parameters fixed. The probe runs
// under `side_query_depth`, and `checkExprCached` already withholds its
// answers from the `node_types` memo — but `typeOfSymbol` is a separate,
// permanent, first-writer-wins memo, and the probe used to publish into it.
//
// Every local the probe declared therefore kept the probe's answer. Here the
// probe pins `bag` (a destructured, un-annotated callback parameter) to `any`,
// so `for (const item of bag.items)` memoizes `item` as `any` — and the
// authoritative pass, which does re-pin `bag` correctly, reads `item` back out
// of the memo as `any` and stops checking the body at all.
//
// Whether the probe or the authoritative walk reaches a body first depends on
// which file demanded the enclosing declaration, so on social-app the
// resulting diagnostics moved with `--file-order` and with `--checkers=N`.
import './use'
