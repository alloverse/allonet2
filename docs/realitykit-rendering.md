# RealityKit rendering measurements

Numbers behind `RealityViewMapper`'s `Text` and `.image` support, measured on macOS 26 / Xcode 27b5
with throwaway probes (`MeshResource.generateText` bounds; offscreen `RealityRenderer` readback of a
4x4 half-transparent PNG over a blue backdrop). They are not documented by Apple and cost an
afternoon to find.

## Text geometry

* **One point is one metre.** `generateText` with a font of point size *p* produces a mesh whose
  glyphs measure *p* metres per em. So `Text.height` (a line height in metres) becomes a font of
  size `height / (ascender - descender + leading)`; that ratio is 1.1777 for the system font, and
  the resulting baseline-to-baseline advance then measures `height` to five decimals.
* Cap height lands at 0.705 x point size, i.e. 0.6 x `Text.height` — a line looks smaller than the
  number says, which is what typography means by line height.
* **The mesh origin is the bottom-left of the *last* line's line box**, not the first: with no
  container frame, extra lines grow upwards. With a container frame, lines stack down from the
  frame's top edge instead. Either way the only safe way to position the block is by measured
  `mesh.bounds` (`Text.placement(ofBlockFrom:to:)`), never by assuming the origin.
* A `.zero` container frame is identical to passing none: no wrapping, `alignment` and
  `lineBreakMode` have no effect. Lines that fall past a real frame's bottom are dropped.
* `generateText("")` returns bounds of `min = +inf, max = -inf`. Any placement math over it yields
  NaN, so the empty string must be special-cased before generating.
* `extrusionDepth: 0` gives a flat mesh in the XY plane with all normals `+Z` — no rotation needed
  to satisfy the component's "faces +Z" contract.

## Texture alpha

For a PNG with fully transparent texels:

| material | transparent texels render as |
| --- | --- |
| `baseColor = .init(texture:)` alone (PBR or Unlit) | opaque black |
| `+ blending = .transparent(opacity: .init(scale: 1))` | the backdrop — correct |
| `+ blending = .transparent(opacity: .init(texture:))` | backdrop, but *opaque* texels also go semi-transparent |
| `+ opacityThreshold = 0.5` | the backdrop, but as a hard cutout (no soft edges) |

So the texture's own alpha is only read when the material blends, and handing the same texture in as
the opacity map applies alpha twice. `opacityThreshold` is the cheap cutout, wrong for antialiased
logo edges.
