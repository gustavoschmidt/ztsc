// `as const` recurses into nested array and object literals; every nested
// element/property is readonly too.
const cfg = { pos: [1, 2], meta: { name: "z" } } as const;
const px: 1 = cfg.pos[0];
const nm: "z" = cfg.meta.name;
cfg.pos[0] = 3;
cfg.meta.name = "q";
