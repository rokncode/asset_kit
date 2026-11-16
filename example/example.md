# asset_kit example

## 1. Set up

```sh
dart pub global activate asset_kit
cd my_flutter_app
asset_kit init
```

Put your high-resolution originals in `assets_src/`:

```
assets_src/
  images/
    logo@3x.png
    onboarding/step_1.png
    شعار.png
  icons/home.svg
  fonts/
    Cairo-Regular.ttf
    Cairo-Bold.ttf
```

A complete config is in [asset_kit.yaml](asset_kit.yaml).

## 2. Build

```sh
asset_kit build
```

```
Optimize
[1/6] images/logo@3x.png → logo.webp (3 variants)
...
File                    Files out  Original  Optimized  Saved
images/logo@3x.png              3   48.2 KB    9.10 KB  81.1%
...

Sync pubspec.yaml
  + assets/icons/
  + assets/images/
  + assets/images/onboarding/
  + font Cairo (400, 700)

Generate
✓ Wrote lib/gen/assets.gen.dart (4 assets).
```

## 3. Use the generated constants

```dart
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'gen/assets.gen.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Image.asset(Assets.images.logo),
        Image.asset(Assets.images.logoAr), // from codegen.names
        Image.asset(Assets.images.onboarding.step1),
        SvgPicture.asset(Assets.icons.home),
        const Text(
          'مرحبا بك',
          style: TextStyle(fontFamily: FontFamily.cairo, fontWeight: FontWeight.w700),
        ),
      ],
    );
  }
}
```

Flutter picks `assets/images/2.0x/logo.webp` or `3.0x/logo.webp` on high
density screens automatically.

## 4. Keep it clean

```sh
asset_kit watch                                  # rebuild while you work
asset_kit unused                                 # report unused and broken
asset_kit unused --delete                        # remove unused (asks first)
asset_kit unused --fail-on-unused --fail-on-broken   # in CI
```
