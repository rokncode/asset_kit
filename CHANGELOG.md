## 0.1.0

Initial release.

- `init`: creates `asset_kit.yaml` and the source folder.
- `optimize`: converts images to WebP with `cwebp` (falls back to optimized
  PNG, and JPEG for photos, when it is missing), generates `2.0x`/`3.0x`
  variants without ever upscaling, applies EXIF rotation, strips metadata,
  optimizes SVGs (optional `.vec` precompilation), and skips unchanged files
  using a hash cache.
- `gen`: generates stable, nested `Assets` constants and a `FontFamily` class
  that pass `dart format` and `dart analyze`. Names that can't be converted
  cleanly (e.g. Arabic file names) are set in `codegen.names`.
- `unused`: reports unused, possibly used and orphan assets and broken
  references, with `--delete`, `--json`, `--fail-on-unused` and
  `--fail-on-broken`.
- `build`: optimize, then sync `pubspec.yaml` (asset folders and font families,
  comments kept, backup written), then gen.
- `watch`: debounced rebuilds when the source folder or config changes.
