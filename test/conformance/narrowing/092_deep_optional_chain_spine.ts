// A truthy optional chain narrows every receiver on its spine, including the
// deep ones: element accesses count as path links, so a guard like this legend
// walk reaches eight of them (`Legend`, `[0]`, `rules`, `[0]`, `symbolizers`,
// `[0]`, `Raster`, `colormap`) before the final read.
type Entry = { color: string; label: string };
type Sym = { Raster?: { colormap?: { entries?: Entry[] } } };
type Rule = { symbolizers?: Sym[] };
type LegendEntry = { layerName?: string; rules?: Rule[] };
type LegendResponse = { Legend?: LegendEntry[] };

export function f(data: LegendResponse): string[] {
  const out: string[] = [];
  if (
    data?.Legend?.[0].layerName === 'X' &&
    data?.Legend?.[0].rules?.[0]?.symbolizers?.[0]?.Raster?.colormap?.entries
  ) {
    const entries = data.Legend[0].rules[0].symbolizers[0].Raster.colormap.entries;
    out.push(entries[0].color);
  }
  return out;
}
