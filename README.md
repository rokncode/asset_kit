# asset_kit

A command-line tool that manages the assets of a Flutter project:

- **Optimizes images**: converts them to WebP, resizes them into Flutter's
  `2.0x` / `3.0x` resolution variants (never upscaling), strips metadata and
  applies EXIF rotation.
- **Generates type-safe constants**: `Assets.images.logo` instead of
  `'assets/images/logo.webp'`, plus a `FontFamily` class.
- **Finds unused assets and broken references**, so you can shrink the app
  bundle and catch paths that will fail at runtime.
- **Keeps `pubspec.yaml` in sync**: asset folders and font families, edited in
  place with your comments preserved.

```dart
Image.asset(Assets.images.logo)                       // 'assets/images/logo.webp'
Image.asset(Assets.images.onboarding.step1)           // 'assets/images/onboarding/step_1.webp'
Text('مرحبا', style: TextStyle(fontFamily: FontFamily.cairo))
```

## Installation

Requires Dart 3.11 or later (Flutter with Dart 3.11+).

```sh
dart pub global activate --source path /path/to/asset_kit
# or, once published:
dart pub global activate asset_kit
```

Make sure `~/.pub-cache/bin` is on your `PATH`, then run `asset_kit --help`.

### WebP encoder (recommended)

WebP output uses `cwebp` from libwebp. asset_kit detects it at startup.

| OS            | Install                                                                |
| ------------- | ---------------------------------------------------------------------- |
| macOS         | `brew install webp`                                                    |
| Debian/Ubuntu | `sudo apt install webp`                                                |
| Fedora        | `sudo dnf install libwebp-tools`                                       |
| Windows       | `choco install webp` or `scoop install libwebp`, or [download libwebp](https://developers.google.com/speed/webp/download) and add `bin/` to `PATH` |

Without `cwebp`, asset_kit doesn't fail: it writes optimized PNGs instead, and
JPEG photos stay JPEG (a photo as lossless PNG would be several times larger).
Set `ASSET_KIT_CWEBP=/path/to/cwebp` to use a specific binary.

## Quick start

```sh
cd my_flutter_app
asset_kit init            # creates asset_kit.yaml and assets_src/
# drop high-resolution originals into assets_src/, e.g. assets_src/images/logo@3x.png
asset_kit build           # optimize + pubspec sync + gen
```

Then use the generated constants:

```dart
import 'package:my_app/gen/assets.gen.dart';

Image.asset(Assets.images.logo);
SvgPicture.asset(Assets.icons.home);
```

During development, keep it running:

```sh
asset_kit watch
```

## How it works

You keep **originals** in `assets_src/` (exported at 3x or 4x). asset_kit
writes the processed, resolution-aware files to `assets/`, which Flutter
bundles:

```
assets_src/images/logo@3x.png      →   assets/images/logo.webp          (1x)
                                       assets/images/2.0x/logo.webp
                                       assets/images/3.0x/logo.webp
```

- **Source scale** comes from a file name suffix (`logo@4x.png` → 4x, output
  name `logo`), else from `folder_scales`, else from `source_scale`.
- **Never upscales**: if an original is too small for a scale, that variant is
  skipped with a warning.
- **SVGs** are optimized (editor metadata, comments, unused ids, empty groups
  and excess precision are removed, and rendering is unchanged) and copied
  without scale variants. They can also be precompiled to `.vec` for
  `package:vector_graphics`.
- **Fonts** and other files (JSON, Lottie…) are copied as-is.
- **Incremental**: a hash cache in `.asset_kit/cache.json` skips files whose
  source and settings haven't changed. When you delete or rename an original,
  its old outputs are removed. Files you put in `assets/` by hand are never
  deleted.

Add `.asset_kit/` to `.gitignore` (`init` does this for you). Commit both
`assets_src/` and `assets/`, or only `assets_src/` and run `asset_kit build`
in CI.

## Commands

| Command | What it does |
| --- | --- |
| `asset_kit init [--force]` | Create `asset_kit.yaml` and the source folder. |
| `asset_kit optimize [--force] [-j N] [--[no-]precompile-svg]` | Compress, convert and generate scale variants. Prints a size table. |
| `asset_kit gen` | Generate the Dart constants file. |
| `asset_kit unused [options]` | Report unused assets, broken references and orphan files. |
| `asset_kit build [--force] [-j N]` | `optimize`, then pubspec sync, then `gen`; warns about broken references. |
| `asset_kit watch [--debounce ms]` | Run `build`, then rebuild whenever `assets_src/` or `asset_kit.yaml` changes. |

Global flags: `--dry-run` (show what would change, write nothing), `-v/--verbose`,
`-c/--config <path>` (paths in the config are relative to the config file).

`unused` options:

| Flag | |
| --- | --- |
| `--delete` | Delete unused assets after confirmation (all scale variants, and SVG + `.vec` together). Unused orphan files get a separate confirmation. |
| `--include-source` | With `--delete`, also delete the originals in `assets_src/`. Without it, `optimize` would recreate them. |
| `-y/--yes` | Don't ask (required with `--delete` when there is no terminal). |
| `--json` | Machine-readable report on stdout (other output goes to stderr). |
| `--fail-on-unused` | Exit 1 if anything is unused. |
| `--fail-on-broken` | Exit 1 if a path in code points at a missing file. |

### Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Success |
| 1 | Failure: a file couldn't be processed, or `--fail-on-*` triggered |
| 64 | Invalid command line usage |
| 65 | Malformed input (e.g. invalid `pubspec.yaml`) |
| 70 | Internal error |
| 74 | File system error |
| 78 | Invalid `asset_kit.yaml` |

## Configuration reference

`asset_kit.yaml` at the project root. Every key is optional; these are the
defaults. Unknown keys produce a warning (catches typos); invalid values fail
with the line and column.

```yaml
source: assets_src          # originals
output: assets              # processed files, bundled by Flutter

source_scale: 3             # scale the originals were exported at
folder_scales:              # per-folder override, relative to `source`;
  images/illustrations: 4   # the most specific folder wins
scales: [1, 2, 3]           # variants to generate; must include 1

images:
  format: webp              # webp | png | keep
  quality: 80               # 0-100, for lossy encodes
  lossless_for: ["*.icon.png"]  # globs (file name or path in `source`)

svg:
  optimize: true
  precompile: false         # also write .vec (needs dev:vector_graphics_compiler)

fonts:
  register_in_pubspec: true
  overrides:                # for file names that can't be parsed
    fonts/Tajawal-Hairline.ttf: { family: Tajawal, weight: 100 }
    fonts/خط-عريض.ttf: { family: خط, weight: 700, style: italic }

codegen:
  output: lib/gen/assets.gen.dart
  class_name: Assets
  names:                    # identifiers for names that can't be converted
    images/شعار.webp: logoAr
    font:خط: arabicDisplay  # FontFamily constant for a family

unused:
  scan_dirs: [lib]
  ignore: ["assets/images/onboarding/*"]        # never reported
  extra_scan_files: ["assets/config/*.json", "lib/l10n/*.arb"]
```

Paths in `codegen.names` and `fonts.overrides` are relative to `output`.

## Generated code

```dart
// GENERATED CODE - DO NOT MODIFY BY HAND
abstract final class Assets {
  static const icons = _Icons();
  static const images = _Images();
}

final class _Images {
  const _Images();
  final String logo = 'assets/images/logo.webp';
  final _ImagesOnboarding onboarding = const _ImagesOnboarding();
}

final class _ImagesOnboarding {
  const _ImagesOnboarding();
  final String step1 = 'assets/images/onboarding/step_1.webp';
}

abstract final class FontFamily {
  static const String cairo = 'Cairo';
}
```

- Nested classes mirror the folder structure. Only 1x paths are referenced;
  Flutter picks `2.0x/` and `3.0x/` automatically.
- File names become lowerCamelCase: `step-2` → `step2`, `1st place` →
  `asset1stPlace`, `default` → `defaultAsset`.
- **Identifiers are stable**: adding a file never renames an existing
  constant. Two files with the same name and different extensions get the
  extension appended (`logoPng`, `logoSvg`). Anything else that would need
  numbering (`my-icon.svg` and `my_icon.svg`), and names with non-ASCII
  characters such as Arabic file names, are **left out** with a warning that
  shows the exact `codegen.names` lines to add.
- The output matches `dart format` for your project's SDK version and
  `formatter: page_width`, and passes `dart analyze` with no issues.

## Fonts

Font files in the output folder are grouped by family and registered under
`flutter: fonts:`:

| File | Family | Weight | Style |
| --- | --- | --- | --- |
| `Cairo-Bold.ttf` | Cairo | 700 | normal |
| `Cairo-BoldItalic.ttf` | Cairo | 700 | italic |
| `NotoKufiArabic-SemiBold.ttf` | NotoKufiArabic | 600 | normal |
| `Cairo[wght].ttf`, `Cairo-VariableFont_wght.ttf` | Cairo | (variable) | normal |

Weight names (case-insensitive): Thin 100, ExtraLight/UltraLight 200,
Light 300, Regular/Book/Normal 400, Medium 500, SemiBold/DemiBold 600,
Bold 700, ExtraBold/UltraBold 800, Black/Heavy 900. `Italic` anywhere in the
suffix sets the italic style.

- **Variable fonts** (detected by name or by an `fvar` table in the file) are
  registered once without a weight. Set the weight in Flutter with
  `fontWeight`, or `FontVariation('wght', 650)` for in-between values.
- **Unknown suffixes** (`Tajawal-Hairline.ttf`) are never guessed: they are
  skipped, and you get the `fonts.overrides` lines to add.
- **Duplicates** (two files with the same family, weight and style) fail with
  both file names.
- Families you registered by hand with files outside `assets/` are left alone.

## Unused assets and broken references

`asset_kit unused` scans every `.dart` file in `scan_dirs` (except the
generated file) and reports four groups:

- **Broken references**: string paths into `assets/` that point at a file
  that doesn't exist, typically code left over after a PNG → WebP conversion.
  Each comes with the file and line, and the likely replacement:
  ```
  lib/screens/home.dart:15  assets/images/logo.png
      ↳ did you mean 'assets/images/logo.webp' or Assets.images.logo?
  ```
- **Unused**: nothing references the asset.
- **Possibly used** (never deleted): the asset matches a dynamic path such as
  `'assets/flags/$code.webp'`, its folder is used as a path prefix, or its
  folder object is stored in a variable (`final o = Assets.images.onboarding;`)
  so individual members can't be tracked.
- **Orphan files**: files in `assets/` that weren't built from `assets_src/`.

An asset counts as used when the scanner finds:
- a generated constant (`Assets.images.logo`, `FontFamily.cairo`);
- its path or file name in a string;
- a reference in `pubspec.yaml` (`flutter_launcher_icons`,
  `flutter_native_splash`, fonts by family name), in
  `flutter_launcher_icons*.yaml` / `flutter_native_splash*.yaml`, in
  `unused.extra_scan_files`, or in Android/iOS/macOS native sources.

Comments are ignored. Sizes include all scale variants.

## CI

```yaml
# .github/workflows/assets.yml
name: assets
on: [pull_request]

jobs:
  assets:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: dart-lang/setup-dart@v1
      - run: sudo apt-get install -y webp
      - run: dart pub global activate asset_kit

      # Assets must be up to date: rebuilding changes nothing.
      - run: asset_kit build
      - run: git diff --exit-code -- assets lib/gen pubspec.yaml

      # No dead weight in the bundle, no paths that crash at runtime.
      - run: asset_kit unused --fail-on-unused --fail-on-broken

      # Optional: machine-readable report as a build artifact.
      - run: asset_kit unused --json > unused-report.json
        if: always()
      - uses: actions/upload-artifact@v4
        if: always()
        with:
          name: unused-report
          path: unused-report.json
```

## Development

```sh
dart pub get
dart test          # unit + integration tests (WebP tests need cwebp)
dart analyze
```

The fixture project in `test/fixtures/sample_app` covers the edge cases:
Arabic file names, scale variants, orphans, dynamic paths, launcher icon and
splash configs, and fonts.
