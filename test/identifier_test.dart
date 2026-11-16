import 'package:asset_kit/src/codegen/identifier.dart';
import 'package:test/test.dart';

void main() {
  group('toLowerCamelCase', () {
    final cases = {
      'logo': 'logo',
      'step_1': 'step1',
      'step-2': 'step2',
      'my logo dark': 'myLogoDark',
      'my-logo.dark': 'myLogoDark',
      'App_Icon': 'appIcon',
      'appIcon': 'appIcon',
      'HTTPLogo': 'httpLogo',
      'ICON': 'icon',
      'icon2x': 'icon2x',
      'iconV2': 'iconV2',
      '__weird--name__': 'weirdName',
      // Leading digits.
      '1st place': 'asset1stPlace',
      '404': 'asset404',
      '3d_cube': 'asset3dCube',
      // Reserved words and Object members.
      'default': 'defaultAsset',
      'class': 'classAsset',
      'new': 'newAsset',
      'Switch': 'switchAsset',
      'hash_code': 'hashCodeAsset',
      'to-string': 'toStringAsset',
      // Built-in identifiers are fine as field names.
      'get': 'get',
      'static': 'static',
    };
    cases.forEach((input, expected) {
      test('"$input" → $expected', () => expect(toLowerCamelCase(input), expected));
    });

    test('names without ASCII letters fall back', () {
      expect(toLowerCamelCase('شعار'), 'asset');
      expect(toLowerCamelCase('---'), 'asset');
      expect(hasNoIdentifierChars('شعار'), isTrue);
      expect(hasNoIdentifierChars('logo_ar'), isFalse);
    });

    test('mixed Arabic and Latin keeps the Latin part', () {
      expect(toLowerCamelCase('شعار_logo'), 'logo');
    });

    test('result is always a valid identifier', () {
      final valid = RegExp(r'^[a-z][A-Za-z0-9]*$');
      for (final input in ['', ' ', '9', 'a b c', 'Ünïcödé', 'x.y.z', '1-2-3']) {
        expect(toLowerCamelCase(input), matches(valid), reason: input);
      }
    });
  });

  test('isCleanlyConvertible', () {
    for (final ok in ['logo', 'step-2', 'My Logo', '1st_place', 'a.b']) {
      expect(isCleanlyConvertible(ok), isTrue, reason: ok);
    }
    for (final bad in ['شعار', 'logo_شعار', 'café', '---', '']) {
      expect(isCleanlyConvertible(bad), isFalse, reason: bad);
    }
  });

  test('isValidMemberName', () {
    for (final ok in ['logo', 'logoAr', 'a1', 'get']) {
      expect(isValidMemberName(ok), isTrue, reason: ok);
    }
    for (final bad in ['Logo', 'logo_ar', '1a', 'class', 'hashCode', '', 'شعار']) {
      expect(isValidMemberName(bad), isFalse, reason: bad);
    }
  });

  test('toUpperCamelCase', () {
    expect(toUpperCamelCase('images'), 'Images');
    expect(toUpperCamelCase('on-boarding'), 'OnBoarding');
    expect(toUpperCamelCase('2.0x'), '20x');
    expect(toUpperCamelCase('خطوط'), 'Asset');
  });

  test('uniqueIdentifier appends numbers', () {
    final taken = <String>{};
    expect(uniqueIdentifier('logo', taken), 'logo');
    expect(uniqueIdentifier('logo', taken), 'logo2');
    expect(uniqueIdentifier('logo', taken), 'logo3');
    expect(taken, {'logo', 'logo2', 'logo3'});
  });
}
