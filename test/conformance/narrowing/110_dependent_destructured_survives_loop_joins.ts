// A loop label's back-edge walk must not publish its answers to the
// persistent flow cache. tsc drops `flowTypeCache` for the whole of
// `getTypeAtFlowLoopLabel`'s antecedent walk; every node re-walked along a
// back edge is answered against an in-flight ancestor, so "nothing narrows
// here" is only true *for that walk*.
//
// The trigger is an out-of-order flow query: the function has no return
// annotation, so inferring it reads `dominant` at the `return`, which walks
// the loop's back edges BEFORE the body is checked in source order. Under
// the old gate that walk cached "no narrowing" at every join between the
// guards in the body, and the sibling narrowing `if (!ok) continue` gave the
// destructured `mime` was lost from the first join onwards.

type Classified =
  | { ok: true; kind: "video" | "image" | "gif"; mime: string }
  | { ok: false; kind: undefined; mime: undefined };

declare function classify(n: number): Classified;
declare function isVideoMime(m: string): boolean;
declare function isImageMime(m: string): boolean;

function collect(ns: number[], allowed: "video" | "image" | "gif" | undefined) {
  // `dominant` is assigned inside the loop from an expression that reads a
  // sibling binding, so resolving it at the `return` re-walks the whole body.
  let dominant: "video" | "image" | "gif" | undefined;
  const out: { mime: string }[] = [];

  for (const n of ns) {
    const { ok, kind, mime } = classify(n);

    if (!ok) {
      continue;
    }

    dominant = allowed || dominant || kind;

    if (kind !== dominant) {
      continue;
    }

    if (kind === "video") {
      if (!isVideoMime(mime)) {
        continue;
      }
    }

    if (kind === "image") {
      if (!isImageMime(mime)) {
        continue;
      }
    }

    // After two joins the sibling narrowing must still hold: `mime` is
    // `string`, not `string | undefined`.
    out.push({ mime });
  }

  return { type: dominant, out };
}

// The same shape reached through a labelled `continue` and an aliased
// disjunction, which is how social-app's thread traversal spells it.
type Item =
  | { $type: "post"; post: { uri: string } }
  | { $type: "blocked"; reason: string }
  | { $type: "notFound"; reason: string };

declare function isPost(v: Item): v is Extract<Item, { $type: "post" }>;
declare function isBlocked(v: Item): v is Extract<Item, { $type: "blocked" }>;

function walk(items: { value: Item }[]) {
  let last: string | undefined;
  const uris: string[] = [];

  traversal: for (const item of items) {
    const stop = isBlocked(item.value) || item.value.$type === "notFound";

    if (stop) {
      last = "stopped";
      continue traversal;
    } else if (isPost(item.value)) {
      const post: { uri: string } = item.value.post;
      uris.push(post.uri);
      continue traversal;
    }

    last = "other";
  }

  return { last, uris };
}

export { collect, walk };
