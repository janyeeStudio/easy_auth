import 'package:easy_auth/src/apple_login_platform.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('only iOS uses native Sign in with Apple', () {
    expect(shouldUseNativeAppleLogin(TargetPlatform.iOS), isTrue);
    expect(shouldUseNativeAppleLogin(TargetPlatform.macOS), isFalse);
    expect(shouldUseNativeAppleLogin(TargetPlatform.android), isFalse);
    expect(shouldUseNativeAppleLogin(TargetPlatform.windows), isFalse);
    expect(shouldUseNativeAppleLogin(TargetPlatform.linux), isFalse);
  });
}
