import 'dart:io';

import 'package:asset_kit/src/runner.dart';

Future<void> main(List<String> args) async {
  final code = await AssetKitRunner().run(args);
  await Future.wait([stdout.flush(), stderr.flush()]);
  exit(code);
}
