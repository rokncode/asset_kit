import 'package:flutter/widgets.dart';

import 'gen/assets.gen.dart';

class Home extends StatelessWidget {
  const Home({super.key, required this.countryCode});

  final String countryCode;

  @override
  Widget build(BuildContext context) {
    // Image.asset(Assets.images.backgroundOld) — commented out, so unused.
    /* Also commented: 'assets/images/background_old.webp' */
    return Column(
      children: [
        Image.asset(Assets.images.logo),
        Image.asset('assets/icons/home-icon.svg'),
        // Dynamic path: flags should be reported as "possibly used".
        Image.asset('assets/images/flags/$countryCode.webp'),
        Text('Hi', style: TextStyle(fontFamily: 'Cairo')),
      ],
    );
  }
}
