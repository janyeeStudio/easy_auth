import 'package:easy_auth/src/apple_login_platform.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native Apple login follows the macOS signing configuration', () {
    expect(shouldUseNativeAppleLogin(TargetPlatform.iOS), isTrue);
    expect(shouldUseNativeAppleLogin(TargetPlatform.macOS), isFalse);
    expect(
      shouldUseNativeAppleLogin(TargetPlatform.macOS, nativeMacOS: true),
      isTrue,
    );
    expect(
      shouldUseNativeAppleLogin(TargetPlatform.android, nativeMacOS: true),
      isFalse,
    );
    expect(shouldUseNativeAppleLogin(TargetPlatform.android), isFalse);
    expect(shouldUseNativeAppleLogin(TargetPlatform.windows), isFalse);
    expect(shouldUseNativeAppleLogin(TargetPlatform.linux), isFalse);
  });
}
