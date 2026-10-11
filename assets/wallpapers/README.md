# Session wallpaper pool

`wallpaper-01.png` through `wallpaper-10.png` are temporary black backgrounds
with large white numbers for verifying random selection. They are opaque
1672 × 941 PNG images, approximately 16:9.

To use a custom set, remove the numbered PNG files and put your images in
this directory, then rebuild the container image. Use `.png`, `.jpg`,
`.jpeg`, or `.svg` filenames; extensions are case insensitive. Filenames
may contain spaces. Images must be readable regular files. The script
looks only at this directory, ignoring subdirectories and this README.
There is no required image count; a pool of one always selects that image.
Use wide images for the default 1920 × 1080 desktop: XFCE zooms each image
to fill the screen while preserving its aspect ratio.

The image build copies this pool to
`/usr/share/backgrounds/remote-desktop/`. A new random choice is made at
each container start, including restarts; consecutive choices may repeat.
It remains fixed during that session and is shared by all workspaces.
Users can still change their background during a session; the next start
selects from this pool again. If selection or configuration fails, XFCE
uses its existing background settings.

## Generation provenance

Generated with the built-in `image_gen` tool, one call for each number
from 1 through 10, with `transparent_background=false`. The generated
outputs were copied unchanged into this directory and each number was
visually checked. No image editing or resizing was applied.

All ten prompts used the following text, replacing `{number}` with the
corresponding number:

```text
Use case: productivity-visual
Asset type: temporary remote desktop wallpaper, wide 16:9 raster image, 1920x1080 pixels preferred.
Primary request: a completely solid pure black background with one large white number centered exactly in the image.
Text (verbatim): "{number}"
Typography: plain bold sans-serif, white, easy to read at remote desktop resolution; numeral height about one quarter of the image height.
Composition: single number at the horizontal and vertical center, ample empty black space around it.
Constraints: opaque black background; only the exact requested number, no additional text, letters, logos, gradients, textures, objects, borders, shadows, or watermarks.
```
