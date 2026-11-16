import 'package:flutter/widgets.dart';

import '../gen/assets.gen.dart';

// The folder object is stored in a variable, so the scanner can't tell
// which members are used: everything in onboarding/ is "possibly used".
final steps = Assets.images.onboarding;

Widget step(int i) => Image.asset(i == 1 ? steps.step1 : steps.step2);

// Only the precompiled .vec is referenced; its .svg is used too.
const arrow = 'assets/icons/arrow_back.vec';

// Stale path from before the WebP conversion: a broken reference.
const oldLogo = 'assets/images/logo.png';
