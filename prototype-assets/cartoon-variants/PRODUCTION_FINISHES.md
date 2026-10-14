# Production finish illustrations

Generated and visually inspected 2026-10-14. All final files are 580×352 RGBA PNGs, approximately 150–168 KB each. They are losslessly encoded after alpha trimming and high-quality resampling. Runtime resources were not modified.

| Product / finish | Final file | Illustrated character |
| --- | --- | --- |
| LSX II LT Stone White | `production-lt-stone-white.png` | Warm white cabinet, warm silver cone, dark metallic center |
| LSX II LT Sage Green | `production-lt-sage-green.png` | Dark sage cabinet, green cone, near-black green center |
| LSX II Carbon Black | `production-lsxii-carbon-black.png` | Carbon cabinet, dark gray cone, gold center |
| LSX II Mineral White | `production-lsxii-mineral-white.png` | Clean white cabinet, silver cone, gold center |
| LSX II Cobalt Blue | `production-lsxii-cobalt-blue.png` | Cobalt cabinet, champagne cone, gold center |
| LSX II Lava Red | `production-lsxii-lava-red.png` | Red cabinet and cone, deep red center |
| LSX II Olive Green | `production-lsxii-olive-green.png` | Previously approved olive/copper palette |
| LSX II Soundwave by Terence Conran | `production-lsxii-soundwave.png` | Warm taupe cabinet, champagne cone, cobalt center, subtle side wave lines |
| LSX II Cotton White | `production-lsxii-cotton-white.png` | Soft warm white cabinet, silver cone, gold center |
| LSX II Amber Haze | `production-lsxii-amber-haze.png` | Golden amber cabinet, champagne cone, bronze center |

## Geometry and alignment

All use the approved official cabinet mesh, smooth C illustration shader, 11° inward pair, camera, simplified Uni-Q geometry, and no wordmark. The near-black finned center approved for LT Graphite is not applied to other finishes when their official center accent differs.

Raw renders are retained as `production-<finish>-raw.png` (1200×750). Every raw render has alpha bounds `(165, 113, 1035, 641)`, exclusive maximum, yielding 870×528 before resizing to 580×352. The normalized driver centers in final images are `(0.258378267, 0.516841636)` and `(0.741621774, 0.516841636)`.

## Visual assumptions

- Colors are visual interpretations of official KEF product imagery, not calibrated manufacturer paint specifications.
- Fabric grain is intentionally omitted to preserve the approved smooth illustration. Cotton and Mineral White therefore differ only subtly in tone; their real-world surface texture distinction is not reproduced.
- Soundwave keeps a restrained wave-line cue, not a literal reproduction of its weave.
- Olive preserves the earlier approved olive/copper rendering. Its tiny red fabric/center/base accents and signature are omitted at this UI scale.
- Cotton White and Amber Haze are finish updates to LSX II; KEF describes the same underlying engineering. The shared cabinet geometry is retained.
- LSX II and LT use the same approved exterior silhouette for consistent UI alignment; rear connector differences are not represented.

## Sources

- [KEF LSX II LT official page](https://us.kef.com/products/lsx-2-lt) and its finish-specific official product images.
- [KEF LSX II official page](https://us.kef.com/products/lsx-2), including its official product image set for current and earlier finishes.
- [KEF LSX II 2024 information sheet](https://assets.kef.com/product-support/lsx-2/LSX_II_Info_sheet_EN_20240328_V12_20240409112820.pdf) for the six earlier finish names.
- [KEF Cotton White and Amber Haze announcement](https://ap.kef.com/blogs/news/kef-lsx-ii-new-colours-cotton-white-amber-haze), which identifies Cotton White as the fabric-finished successor to Mineral White and describes Amber Haze's yellow/red yarns.

## Reproduction

Run `python3 render_finish_set.py` from this folder. It invokes Blender with `render_variants.py`, then trims and resamples the renders using Pillow. The default model input is `/tmp/kef-models/lsx2lt-graphite.glb`; the renderer also accepts an explicit GLB path.
